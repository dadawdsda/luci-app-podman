#!/usr/bin/env ucode
// Podman SSE stream daemon. One process publishes a control object
// (podman_stream) plus per-(kind,id,params) data objects that uhttpd's
// /ubus/subscribe/ endpoint serves as Server-Sent Events. Each data object
// opens its single-container Podman stream only while it has subscribers.
//
// Managed by procd (/etc/init.d/podman-stream), started on demand by the client.
//
// Kinds: stats, top (NDJSON snapshots), logs (multiplexed stdout/stderr frames,
// or raw for TTY; live with reconnect-resume, or one-shot bounded fetch).
//
// Reclamation/security model (see docs/plan-sse-stats-production.md):
//   - continuous stream (never renews the LuCI session)
//   - per-object backstop obj.remove() after ~luci.sauth.sessiontime
//   - stream-count cap below uhttpd.max_connections leaves headroom for LuCI
'use strict';

import { connect } from 'ubus';
import * as uloop from 'uloop';
import { cursor } from 'uci';
import * as struct from 'struct';
import * as podman_socket from 'luci.podman_socket'; // ucode-lsp disable
import { API_BASE } from 'luci.podman_socket'; // ucode-lsp disable
import { build_request, parse_status } from 'luci.podman_http'; // ucode-lsp disable
import { validate_id } from 'luci.podman_validate'; // ucode-lsp disable
import { sha256 } from 'digest';

const BLOCKSIZE   = 4096;
const SWEEP_MS    = 2000;
const GC_IDLE     = 30;   // unregister an idle (no-subscriber) object after Ns
const BACKOFF_MAX = 60;   // cap between retries of a failing/ended stream
const KINDS       = { stats: true, top: true, logs: true };

// Respect existing system config: cap streams below uhttpd's connection limit,
// align the backstop with the session timeout.
const cfg = (() => {
	let c = cursor();
	let maxconn  = +(c.get('uhttpd', 'main', 'max_connections') || 100);
	let sesstime = +(c.get('luci', 'sauth', 'sessiontime') || 3600);
	let nettmo   = +(c.get('uhttpd', 'main', 'network_timeout') || 30);
	let override = +(c.get('luci-podman', 'globals', 'stream_max') || 0);
	c.unload('uhttpd'); c.unload('luci'); c.unload('luci-podman');
	if (!maxconn) maxconn = 100;
	if (!sesstime) sesstime = 3600;
	if (!nettmo) nettmo = 30;
	let cap = override > 0 ? override : int(maxconn / 2);
	if (cap < 4) cap = 4;
	// CRITICAL: the backstop MUST fire before uhttpd's network_timeout. A dead SSE
	// subscriber that lingers until network_timeout CRASHES uhttpd (a uhttpd-mod-ubus
	// defect in the subscribe-connection timeout cleanup; repeated -> procd crash
	// loop -> UI down). obj.remove() before then closes it via a clean path.
	// Capped at sessiontime so that, when an admin raises network_timeout to
	// >= sessiontime, the recycle also enforces session expiry (no immortal sessions).
	let backstop = nettmo - 5;
	if (backstop < 5) backstop = 5;
	if (backstop > sesstime) backstop = sesstime;
	// A gap between ensures longer than this means a genuinely new viewing (resets
	// the deadline); must exceed the reconnect interval (~backstop) so continuous
	// reconnects do NOT extend the deadline.
	let fresh_gap = backstop * 2;
	if (fresh_gap < 60) fresh_gap = 60;
	return { cap, backstop, sessiontime: sesstime, fresh_gap };
})();

const conn = connect();
if (!conn) { warn('[stream] ubus connect failed\n'); exit(1); }

// objectName -> entry. This map holds the live object refs - dropping a ref
// lets ucode GC unregister the object out from under subscribers, so keep it.
let streams = {};

// Coerce an untyped (JSON) value to a number, falling back to `def` on NaN.
/** @param {any} v @param {number} def */
function num(v, def) {
	let n = +v;
	return (n == n) ? n : def; // n != n  =>  NaN  =>  default
}

// Validate/normalize client params into a FIXED key order (stable %J for the
// hash) or null on invalid. ALL params are validated here before reaching the
// Podman URL (the subscribe URL cannot carry params).
/** @param {string} kind @param {object} params */
function normalize_params(kind, params) {
	if (type(params) !== 'object') params = {};
	if (kind === 'stats') {
		let iv = num(params.interval, 3);
		if (iv < 1) iv = 1;
		if (iv > 60) iv = 60;
		return { interval: iv };
	}
	if (kind === 'top') {
		let d = num(params.delay, 5);
		if (d < 2) d = 2;
		if (d > 60) d = 60;
		let pa = params.ps_args;
		if (type(pa) !== 'string') pa = '';
		if (pa !== '' && !match(pa, /^[-a-zA-Z0-9_, ]+$/))
			return null;
		return { delay: d, ps_args: pa };
	}
	if (kind === 'logs') {
		let tail = params.tail;
		if (tail !== 'all') {
			tail = num(tail, 100);
			if (tail < 1) tail = 1;
			if (tail > 1000) tail = 1000;
		}
		let since = num(params.since, 0); if (since < 0) since = 0;
		let until = num(params.until, 0); if (until < 0) until = 0;
		return {
			tail, since, until,
			follow: params.follow ? true : false,
			tty:    params.tty ? true : false
		};
	}
	return null;
}

/** @param {object} e */
function endpoint_for(e) {
	let id = e.id, p = e.params;
	if (e.kind === 'stats')
		return sprintf('%s/containers/stats?containers=%s&stream=true&interval=%d',
			API_BASE, id, p.interval);
	if (e.kind === 'top') {
		let u = sprintf('%s/containers/%s/top?stream=true&delay=%d', API_BASE, id, p.delay);
		if (p.ps_args)
			u += '&ps_args=' + replace(p.ps_args, / /g, '%20');
		return u;
	}
	if (e.kind === 'logs') {
		let u = sprintf('%s/containers/%s/logs?stdout=true&stderr=true&timestamps=false&follow=%s',
			API_BASE, id, p.follow ? 'true' : 'false');
		// Live restart: resume from the disconnect point (no tail re-dump).
		if (p.follow && e.started_once && e.resume_since > 0) {
			u += sprintf('&since=%d', e.resume_since);
		} else {
			if (p.tail !== 'all') u += sprintf('&tail=%d', p.tail);
			if (p.since > 0) u += sprintf('&since=%d', p.since);
			if (p.until > 0) u += sprintf('&until=%d', p.until);
		}
		return u;
	}
	return null;
}

// --- per-kind body parsers (operate on e.rbuf after HTTP headers) ---

/** @param {object} e */
function parse_ndjson(e) {
	let buf = e.rbuf;
	if (type(buf) !== 'string') return;
	let lines = split(buf, '\n');
	e.rbuf = lines[length(lines) - 1] || '';
	for (let i = 0; i < length(lines) - 1; i++) {
		let line = lines[i];
		if (type(line) !== 'string') continue;
		line = trim(line);
		if (!length(line)) continue;
		let sample = json(line);
		if (type(sample) === 'object')
			e.obj.notify(e.kind, sample);
	}
}

/** @param {object} e */
function parse_logs(e) {
	let buf = e.rbuf;
	if (type(buf) !== 'string') return;

	if (e.params.tty) { // raw byte stream, no multiplexing
		if (length(buf)) { e.obj.notify(e.kind, { raw: buf }); e.rbuf = ''; }
		return;
	}

	// Multiplexed: 8-byte header [stream_type, x, x, x, len(BE u32)] then payload.
	// Merge stdout(1) + stderr(2); client splits the chunk into lines.
	let out = '';
	while (length(buf) >= 8) {
		let hdr = struct.unpack('!BxxxI', substr(buf, 0, 8));
		if (type(hdr) !== 'array') break;
		let stype = hdr[0];
		let plen  = int(`${hdr[1]}`); // template -> string -> int (lsp-clean, cf. controller)
		if (length(buf) < 8 + plen) break; // wait for the full payload
		let payload = substr(buf, 8, plen) || '';
		buf = substr(buf, 8 + plen) || '';
		if (stype >= 1 && stype <= 2) out += payload;
	}
	e.rbuf = buf;
	if (length(out)) e.obj.notify(e.kind, { raw: out });
}

/** @param {object} e */
function stop_stream(e) {
	if (e.shandle) { e.shandle.delete(); e.shandle = null; }
	if (e.sock) { e.sock.close(); e.sock = null; }
	e.rbuf = ''; e.hdr_done = false;
	// Live logs: remember where we stopped so a restart resumes (no tail re-dump).
	if (e.kind === 'logs' && e.params.follow) e.resume_since = time();
}

/** @param {object} e */
function backoff(e) {
	e.backoff = e.backoff ? min(e.backoff * 2, BACKOFF_MAX) : 5;
	e.retry_at = time() + e.backoff;
}

/** @param {object} e */
function on_readable(e) {
	let chunk = e.sock.recv(BLOCKSIZE);
	if (type(chunk) !== 'string') return;          // EAGAIN
	if (!length(chunk)) {                          // Podman closed the stream
		if (e.oneshot) {
			// Bounded query finished: tell the client, then let the sweep remove it.
			if (e.obj) e.obj.notify(e.kind, { done: true });
			stop_stream(e);
			e.finished = true;
		} else {
			// Live source ended (e.g. container stopped): back off to avoid a tight
			// restart loop; the sweep retries after retry_at if still subscribed.
			stop_stream(e);
			backoff(e);
		}
		return;
	}

	e.rbuf += chunk;
	if (type(e.rbuf) !== 'string') return;

	if (!e.hdr_done) {
		let sep = index(e.rbuf, '\r\n\r\n');
		if (type(sep) !== 'int' || sep < 0) return;
		let code = parse_status(e.rbuf) || 0;
		if (code != 200) {
			warn(sprintf('[stream] %s podman HTTP %d -> backoff\n', e.name, code));
			stop_stream(e);
			backoff(e);
			return;
		}
		e.rbuf = substr(e.rbuf, sep + 4) || ''; // ucode-lsp disable
		e.hdr_done = true;
		e.backoff = 0; // 200 OK clears backoff
	}

	e.parse(e);
}

/** @param {object} e */
function start_stream(e) {
	let path = endpoint_for(e);
	if (!path) return;
	e.sock = podman_socket.connect();
	if (!e.sock) {
		warn(sprintf('[stream] %s podman connect failed -> backoff\n', e.name));
		e.sock = null;
		backoff(e);
		return;
	}
	e.rbuf = ''; e.hdr_done = false;
	e.parse = (e.kind === 'logs') ? parse_logs : parse_ndjson;
	e.started_once = true;
	e.sock.send(build_request('GET', path, null));
	e.shandle = uloop.handle(e.sock, () => on_readable(e), uloop.ULOOP_READ);
	warn(sprintf('[stream] %s started\n', e.name));
}

/** @param {string} name */
function remove_stream(name) {
	let e = streams[name];
	if (!e) return;
	stop_stream(e);
	if (e.obj) e.obj.remove(); // closes any SSE connection (uhttpd request_done)
	let ns = {};
	for (let k in streams) if (k != name) ns[k] = streams[k];
	streams = ns;              // drop ref so the object is GC'd
	warn(sprintf('[stream] %s removed\n', name));
}

function sweep() {
	let now = time();
	let to_remove = [];
	for (let name in streams) {
		let e = streams[name];
		if (e.finished) { push(to_remove, name); continue; }   // one-shot completed
		// Backstop (live only; one-shots self-terminate on EOF).
		if (!e.oneshot && now - e.created >= cfg.backstop) { push(to_remove, name); continue; }

		let has = e.obj ? e.obj.subscribed() : false;
		if (has) {
			e.idle_since = 0;
			if (!e.sock && !e.finished && now >= e.retry_at) start_stream(e);
		} else {
			if (e.sock) stop_stream(e);
			if (!e.idle_since) e.idle_since = now;
			else if (now - e.idle_since >= GC_IDLE) push(to_remove, name);
		}
	}
	for (let i = 0; i < length(to_remove); i++) remove_stream(to_remove[i]);
	uloop.timer(SWEEP_MS, sweep);
}

// Enforce session expiry despite reconnects (ported from the controller's
// session_timer): store an absolute deadline on first ensure and DESTROY the
// session when it passes. Reconnects renew rpcd's auto-timer, but this fixed
// deadline + explicit destroy makes the session expire at ~start+sessiontime
// regardless -> no immortal session from a forgotten-but-open tab.
/** @param {string} sid */
function session_ok(sid) {
	if (sid === '') return true; // local ubus call (no injected session) - allow
	let sdat = conn.call('session', 'get', { ubus_rpc_session: sid });
	if (type(sdat) !== 'object') return true; // can't read -> be lenient
	let vals = type(sdat.values) === 'object' ? sdat.values : {};
	let now = time();
	let deadline  = num(vals.podman_stream_deadline, 0);
	let last_seen = num(vals.podman_stream_last_seen, 0);
	if (!deadline || (now - last_seen > cfg.fresh_gap))
		deadline = now + cfg.sessiontime; // fresh viewing -> new window
	if (now >= deadline) {
		conn.call('session', 'destroy', { ubus_rpc_session: sid });
		return false;
	}
	conn.call('session', 'set', {
		ubus_rpc_session: sid,
		values: { podman_stream_deadline: deadline, podman_stream_last_seen: now }
	});
	return true;
}

/** @param {object} request */
function do_ensure(request) {
	let args = request.args || {};
	let kind = args.kind;
	let id   = args.id;

	if (type(kind) !== 'string' || !KINDS[kind])
		return { error: 'unsupported kind' };
	if (type(id) !== 'string' || validate_id(id))
		return { error: 'invalid container id' };

	let np = normalize_params(kind, args.params);
	if (!np)
		return { error: 'invalid params' };

	// Opaque, one-way name = hash(session | kind | container | params): deterministic
	// (reload -> same name -> reuse), leaks neither the session token nor the params,
	// and unguessable without the session id -> de-facto per-session isolation under
	// the broad podman_<kind>_* ACL.
	let sid = type(args.ubus_rpc_session) === 'string' ? args.ubus_rpc_session : '';
	if (!session_ok(sid))
		return { error: 'session expired' };
	let h = sha256(sprintf('%s|%s|%s|%J', sid, kind, id, np));
	if (type(h) !== 'string')
		return { error: 'hash failed' };
	let name = sprintf('podman_%s_%s', kind, substr(h, 0, 24));

	if (streams[name]) {
		streams[name].idle_since = 0; // requested - keep alive
		return { object: name };
	}

	if (length(streams) >= cfg.cap)
		return { error: 'stream limit reached' };

	// Store params (to build the URL); never store the session.
	let e = {
		kind, id, name, params: np, obj: null, sock: null, shandle: null,
		rbuf: '', hdr_done: false, idle_since: 0,
		created: time(), backoff: 0, retry_at: 0, parse: null,
		oneshot: (kind === 'logs' && !np.follow),
		started_once: false, resume_since: 0, finished: false
	};
	// Data object: subscribed-to only. The subscribe callback starts the Podman
	// stream the instant a subscriber arrives (no ~2s sweep delay for first sample).
	e.obj = conn.publish(name, {}, () => {
		if (!e.obj) return; // guard: may fire during publish() before e.obj is set
		if (e.obj.subscribed()) {
			e.idle_since = 0;
			if (!e.sock && !e.finished && time() >= e.retry_at) start_stream(e);
		} else if (e.sock) {
			stop_stream(e);
		}
	});
	if (!e.obj)
		return { error: 'publish failed' };
	streams[name] = e;              // keep ref (GC)
	warn(sprintf('[stream] %s registered\n', name));
	return { object: name };
}

let ctrl = conn.publish('podman_stream', {
	// ubus_rpc_session is injected by uhttpd on HTTP calls; declare it or the
	// call is rejected with INVALID_ARGUMENT.
	ensure: { call: do_ensure, args: { kind: '', id: '', params: {}, ubus_rpc_session: '' } }
});
if (!ctrl) { warn('[stream] publish podman_stream failed\n'); exit(1); }

warn(sprintf('[stream] up; cap=%d backstop=%ds\n', cfg.cap, cfg.backstop));

uloop.init();
uloop.timer(SWEEP_MS, sweep);
uloop.run();
