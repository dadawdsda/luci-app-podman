# Plan: evaluate uhttpd `/ubus/subscribe/` SSE as the streaming transport

Status: **investigation + test plan — not implemented, not yet decided**

Goal: replace the two streaming hacks (the ~1.1 KB write-coalescing padding + the `script_timeout`
forced-reconnect machinery in `ucode/controller/podman.uc`) with uhttpd's native ubus SSE
subscribe endpoint, which is a push path built for streaming.

## Source verification (uhttpd master: ubus.c / utils.c / client.c)

Confirmed by reading the C source:

- **Endpoint exists.** `ubus.c`: `/subscribe/<path>` → `uh_ubus_handle_get_subscribe` →
  `ubus_register_subscriber`; response `Content-Type: text/event-stream`.
- **Per-event write.** Notifications go through `uh_ubus_subscription_notification_cb` →
  `ops->chunk_printf(cl, "event: %s\ndata: %s\n\n", method, json)`.
- **No threshold coalescing.** `uh_chunk_vprintf`/`uh_chunk_write` (`utils.c`) write straight to
  `ustream` — no size-threshold buffer. The ~1.1 KB coalescing the app fights lives in the
  uhttpd-mod-ucode / LuCI dispatch relay, which the subscribe path **bypasses** (pure C).
  *Caveat:* `ustream_write(cl->us, data, len, true)` uses `more=true`; exact flush timing not
  confirmable from source → Phase 1 measures it.
- **Timeout model (premise correction).** There *is* an idle timeout = `conf.network_timeout`
  (default ~30 s, `client.c`). BUT `uh_chunk_vprintf` resets `cl->timeout` to `network_timeout`
  on **every event write** (verified — same `uloop_timeout_set` line as `uh_chunk_write`). So:
  - No `script_timeout` hard cap on this path → no forced <60 s reconnects.
  - Connection lives indefinitely **as long as ≥1 event is sent per `network_timeout`** →
    a lightweight **heartbeat** (`: ping\n\n` every ~20 s) is still needed for quiet periods.
- **Auth.** `uh_ubus_get_auth` reads `Authorization: Bearer <sid>` only; `uh_ubus_allowed(sid,
  path, ":subscribe")` ACL check unless `conf.ubus_noauth`. `EventSource` can't set headers →
  authed streams use `fetch()` + `ReadableStream` + Bearer header (same as current frontend).

## Prerequisite

- `uhttpd-mod-ubus` installed and `option ubus_prefix '/ubus'` set in `/etc/config/uhttpd`.
  Not guaranteed present (LuCI's default path is the dispatcher). Phase 0 settles this.

## The real cost (decide AFTER Phase 0–1)

Transport is the easy part. The hard part is the **producer remodel**:
- A persistent daemon must hold a ubus connection + the Podman socket and translate Podman's
  stream into ubus `notify()` calls on a published object (ucode `ubus.publish()` → object
  `.notify(type, data)`).
- Subscription targets an **object path**, not a parameterized URL. "Logs for container X" needs
  a lifecycle: register a per-stream object on demand, open the Podman stream when the first
  subscriber attaches, tear down when the last leaves. This is the unsolved design question.
- Both transports can coexist during migration (subscribe path is parallel to the LuCI routes).

---

## Test harness (built — remove after testing)

Phase 0–1 (transport):
- `root/usr/share/podman/sse-test-publisher.uc` — persistent ucode daemon: publishes ubus
  object `podman_ssetest`, emits a ~50-byte `tick` notification every 1s.
- `root/usr/share/rpcd/acl.d/luci-app-podman.json` — added `podman_ssetest: [":subscribe"]`
  under `read.ubus` (the grant uhttpd checks via `session.access {function:":subscribe"}`).
- `htdocs/luci-static/resources/view/podman/ssetest.js` + `menu.d` entry `admin/podman/ssetest`
  ("SSE Test") — fetch()+ReadableStream consumer (Bearer-authed) that logs per-event arrival
  gaps so coalescing/longevity are directly visible.

Phase 3 (real stream prototype — stats, PER-CONTAINER + ensure):
- `root/usr/share/podman/stats-publisher.uc` — ONE daemon. Publishes a control object
  `podman_stream` with `ensure({kind,id})`, which lazily registers a per-container object
  `podman_stats_<id>`. A 2s sweep opens the SINGLE-container stream
  (`/containers/stats?containers=<id>&stream=true`) only while that object has subscribers,
  stops it otherwise, and `obj.remove()`s the object after ~30s idle (GC).
- ACL: `podman_stream: ["ensure"]` (call) + `podman_stats_*: [":subscribe"]` (fnmatch wildcard).
- `Container.js`: `streamEnsure` RPC (`podman_stream.ensure`, silent) + `streamStatsViaSSE()`
  now ensures then subscribes to `podman_stats_<id>` and reads `Stats[0]`.
  `container-tab/stats.js` uses it; `streamStats()` (controller path) kept for easy revert.

### Phase 3 RESULTS (validated on r4, 2026-05-26)
First cut used an ALL-containers object (one stream, client filters) — rejected for production:
on an embedded box it streams every running container to show one. Reworked to PER-CONTAINER.
Per-container validated end to end:
- `ensure` → `{"object":"podman_stats_<id>"}`; object registers on the bus on demand.
- Wildcard ACL works: `session.access podman_stats_<id> :subscribe → true` (matched
  `podman_stats_*` via fnmatch — confirmed in rpcd `session.c`).
- Subscribe opens the SINGLE-container stream (verified: a dummy id produced Podman HTTP 404 for
  exactly that id; a real running container streams `{Stats:[...]}`). Only the viewed container
  runs; idle daemon = zero Podman connections; objects GC'd after idle. One process total.
- Published-object API used: `conn.publish(name, methods)` (dynamic at runtime), `obj.notify()`,
  `obj.subscribed()`, `obj.remove()` (unregister). Method handler: `call(request)` with
  `request.args`; returning a plain object replies.
- **CAVEAT 1 — teardown latency**: uhttpd only unsubscribes when its next write to the client
  FAILS; per-interval events keep resetting the 20s idle timeout, so uhttpd never times the dead
  client out itself. Delayed stop, NOT a leak. Fine for stats; quantify for heavier streams.
- **CAVEAT 2 — error retry**: on a stream error the 2s sweep retries (started→404→started…).
  Production should back off / stop on permanent 4xx (e.g. container removed mid-view).
- Real stat VALUES still need a running container to confirm in the browser.
- **GOTCHA (cost real debugging)**: a method on a RAW `conn.publish()` object that is called
  via uhttpd-mod-ubus / the HTTP `/ubus` gateway MUST declare `ubus_rpc_session` in its `args`
  policy. uhttpd injects `ubus_rpc_session` into every HTTP call; a raw-published object validates
  args strictly and rejects the unknown field with `[2]` INVALID_ARGUMENT (local `ubus call`
  works because it doesn't inject it). rpcd-registered methods get this for free. Symptom seen:
  frontend `ensure failed: no object`. Fix: `args: { kind:'', id:'', ubus_rpc_session:'' }`.

## Test plan (staged go/no-go)

Testing methodology note: per project memory, `grep`/`head`/`while-read` buffer when stdout
isn't a TTY. To measure *when* bytes actually reach the client, write to a file and poll its
size (`stat -c %s`) — zero downstream buffering. Use `curl -N` (no curl buffering).

### Phase 0 — transport smoke test (no app, cheap go/no-go)
Confirm the endpoint is reachable, returns `text/event-stream`, and holds open past the old
60 s cap.

```sh
# Needs a session id with :subscribe ACL on <object>, OR temporarily set option ubus_noauth '1'.
SID=$(ubus call session login '{"username":"root","password":"<pw>"}' | jsonfilter -e '@.ubus_rpc_session')
curl -N -H "Authorization: Bearer $SID" http://<host>/ubus/subscribe/<object> -D - -o /tmp/sse.out &
# watch headers (expect 200 + Content-Type: text/event-stream) and that the process stays alive
sleep 75; echo "still open?"; jobs
```
- PASS if: 200 + `text/event-stream`, connection stays open > 60 s (proves no `script_timeout`).
- ACL note: most rpcd ACLs don't grant `:subscribe`. For the smoke test, either grant
  `"subscribe": { "<object>": ["*"] }` (verify exact ACL shape) or use `ubus_noauth` temporarily.
- Even subscribing to a quiet/known object is enough to test hold-open + headers.

### Phase 1 — producer + buffering + idle behavior (the decisive transport test)
Tiny standalone ucode publisher (no Podman yet) to isolate transport characteristics:

```javascript
// /tmp/pub.uc  — run: ucode /tmp/pub.uc
'use strict';
import { connect } from 'ubus';
import * as uloop from 'uloop';
let ctx = connect();
let obj = ctx.publish('podman_test', {
    noop: { call: () => ({}) }
});
uloop.init();
let n = 0;
let t; t = () => { obj.notify('tick', { n: n++, ts: time() }); uloop.timer(1000, t); };
uloop.timer(1000, t);
uloop.run();
```
Measure against `/ubus/subscribe/podman_test`:
- (a) **Latency / no coalescing:** small (~30 byte) events — does each arrive immediately
  (file size grows ~every 1 s), or do they batch? Poll `stat -c %s /tmp/sse.out` every 100 ms.
- (b) **Longevity with frequent events:** runs > 5 min with 1 s ticks, connection never drops.
- (c) **Sparse-event behavior:** raise the timer to `network_timeout + 10` s → confirm the
  connection DROPS (proves the heartbeat requirement) and that a ~20 s heartbeat keeps it alive.
- (d) Confirm `ubus.publish()` / object `.notify()` ucode API shape (get_symbol modules/ubus).

### Phase 2 — auth modes + frontend consumption
- Anonymous (ACL/`ubus_noauth`) via `EventSource('/ubus/subscribe/podman_test')`.
- Authed via `fetch('/ubus/subscribe/podman_test', { headers: { Authorization: 'Bearer ' +
  L.env.sessionid } })` + `ReadableStream` reader splitting on `\n\n`, parsing `data:` lines.
- Confirm the ACL `:subscribe` grant shape in a real `acl.d` file.

### Phase 3 — one real stream prototype (only if 0–2 pass; decision gate)
Pick **stats** (simplest: periodic JSON, no frame parsing like logs, no resume like pull).
- A daemon publishes `podman_stats_<id>`, opens the Podman `/containers/stats?stream=true`
  socket on first subscriber, notifies per sample, tears down on last unsubscribe.
- Surfaces the producer lifecycle/parameterization complexity for real before committing to
  migrating logs/top/pull/export.

## Decision criteria
Proceed to a full migration only if: Phase 1(a) shows no coalescing (padding hack removable),
1(b)+1(c) confirm heartbeat-kept longevity (reconnect machinery removable), and Phase 3 shows
the producer lifecycle is tractable. Otherwise keep the current controller transport.
