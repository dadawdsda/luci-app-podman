#!/usr/bin/env ucode
// PROTOTYPE (Phase 3, per-container): a single persistent ubus publisher that
// serves PER-CONTAINER stat streams over uhttpd's /ubus/subscribe/ SSE path.
//
// Model:
//   - publishes a control object 'podman_stream' with method ensure({kind,id})
//   - ensure() lazily registers a per-(kind,id) object 'podman_<kind>_<id>'
//   - a 2s sweep opens the SINGLE-container Podman stream for an object only
//     while it has subscribers, closes it otherwise, and unregisters (GC) the
//     object after it has been idle (no subscribers, no stream) for ~30s.
//
// So nothing touches Podman until a client subscribes, and only the viewed
// container's stream runs - matching the existing per-container model. One
// process publishes all objects (not a daemon per stream).
//
// Run: ucode /usr/share/podman/stats-publisher.uc >/tmp/stats-pub.log 2>&1 &
'use strict';

import { connect } from 'ubus';
import * as uloop from 'uloop';
import * as podman_socket from 'luci.podman_socket'; // ucode-lsp disable
import { API_BASE } from 'luci.podman_socket'; // ucode-lsp disable
import { build_request, parse_status } from 'luci.podman_http'; // ucode-lsp disable

const BLOCKSIZE = 4096;
const INTERVAL  = 3;    // stats sample interval (seconds)
const GC_IDLE   = 30;   // unregister an idle object after this many seconds
const SWEEP_MS  = 2000;

const conn = connect();
if (!conn) {
	warn('[stream] ubus connect failed\n');
	exit(1);
}

// objectName -> { obj, kind, id, name, sock, shandle, rbuf, hdr_done, idle_since }
let streams = {};

/**
 * @param {string} kind
 * @param {string} id
 */
function endpoint_for(kind, id) {
	// stats only for this prototype; logs/top would parse differently.
	if (kind === 'stats')
		return sprintf('%s/containers/stats?containers=%s&stream=true&interval=%d',
			API_BASE, id, INTERVAL);
	return null;
}

/** @param {object} e */
function stop_stream(e) {
	if (e.shandle) { e.shandle.delete(); e.shandle = null; }
	if (e.sock) { e.sock.close(); e.sock = null; }
	e.rbuf = ''; e.hdr_done = false;
}

/** @param {object} e */
function on_readable(e) {
	let chunk = e.sock.recv(BLOCKSIZE);
	if (type(chunk) !== 'string') return;            // EAGAIN
	if (!length(chunk)) { stop_stream(e); return; }  // Podman closed the stream
	e.rbuf += chunk;
	if (type(e.rbuf) !== 'string') return;

	if (!e.hdr_done) {
		let sep = index(e.rbuf, '\r\n\r\n');
		if (type(sep) !== 'int' || sep < 0) return;
		let code = parse_status(e.rbuf) || 0;
		if (code != 200) {
			warn(sprintf('[stream] %s podman HTTP %d\n', e.name, code));
			stop_stream(e);
			return;
		}
		e.rbuf = substr(e.rbuf, sep + 4) || ''; // ucode-lsp disable
		e.hdr_done = true;
	}

	let lines = split(e.rbuf, '\n');
	e.rbuf = lines[length(lines) - 1] || '';
	for (let i = 0; i < length(lines) - 1; i++) {
		let line = lines[i];
		if (type(line) !== 'string') continue;
		line = trim(line);
		if (!length(line)) continue;
		let sample = json(line);
		if (type(sample) === 'object')
			e.obj.notify('stats', sample); // uhttpd relays as event: stats / data: {...}
	}
}

/** @param {object} e */
function start_stream(e) {
	let path = endpoint_for(e.kind, e.id);
	if (!path) { warn(sprintf('[stream] %s unknown kind\n', e.name)); return; }
	e.sock = podman_socket.connect();
	if (!e.sock) { warn(sprintf('[stream] %s podman connect failed\n', e.name)); e.sock = null; return; }
	e.rbuf = ''; e.hdr_done = false;
	e.sock.send(build_request('GET', path, null));
	e.shandle = uloop.handle(e.sock, () => on_readable(e), uloop.ULOOP_READ);
	warn(sprintf('[stream] %s started\n', e.name));
}

/** @param {string} name */
function gc_remove(name) {
	let e = streams[name];
	if (!e) return;
	if (e.obj) e.obj.remove();     // ubus_remove_object - unregister from the bus
	let ns = {};
	for (let k in streams)
		if (k != name) ns[k] = streams[k];
	streams = ns;
	warn(sprintf('[stream] %s unregistered (gc)\n', name));
}

function sweep() {
	let now = time();
	let to_gc = [];
	for (let name in streams) {
		let e = streams[name];
		let has = e.obj ? e.obj.subscribed() : false;
		if (has) {
			e.idle_since = 0;
			if (!e.sock) start_stream(e);
		} else {
			if (e.sock) { stop_stream(e); warn(sprintf('[stream] %s stopped (no subscribers)\n', e.name)); }
			if (!e.idle_since) e.idle_since = now;
			else if (now - e.idle_since >= GC_IDLE) push(to_gc, name);
		}
	}
	for (let i = 0; i < length(to_gc); i++)
		gc_remove(to_gc[i]);
	uloop.timer(SWEEP_MS, sweep);
}

/** @param {object} request */
function do_ensure(request) {
	let args = request.args || {};
	let kind = args.kind;
	let id   = args.id;

	if (kind !== 'stats')
		return { error: 'unsupported kind' };
	if (type(id) !== 'string')
		return { error: 'invalid container id' };
	if (!match(id, /^[a-zA-Z0-9][a-zA-Z0-9_.-]*$/))
		return { error: 'invalid container id' };

	let name = sprintf('podman_%s_%s', kind, id);

	if (!streams[name]) {
		let e = { kind, id, name, obj: null, sock: null, shandle: null,
		          rbuf: '', hdr_done: false, idle_since: 0 };
		e.obj = conn.publish(name, {
			ping: { call: () => ({ pong: time() }), args: {} }
		});
		if (!e.obj)
			return { error: 'publish failed' };
		streams[name] = e;
		warn(sprintf('[stream] %s registered\n', name));
	}

	streams[name].idle_since = 0; // just requested - reset GC clock
	return { object: name };
}

let ctrl = conn.publish('podman_stream', {
	// ubus_rpc_session is injected by uhttpd-mod-ubus on HTTP calls; it must be
	// declared in the policy or a raw-published object rejects it (INVALID_ARGUMENT).
	ensure: { call: do_ensure, args: { kind: '', id: '', ubus_rpc_session: '' } }
});
if (!ctrl) {
	warn('[stream] publish podman_stream failed\n');
	exit(1);
}

warn('[stream] podman_stream control object up; idle until ensure+subscribe\n');

uloop.init();
uloop.timer(SWEEP_MS, sweep);
uloop.run();
