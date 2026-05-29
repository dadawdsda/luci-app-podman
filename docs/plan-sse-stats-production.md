# Plan: production-ready SSE streaming — stats first

Status: **design locked pending the open decisions at the bottom; not implemented**

## Goal & scope

Make **container stats** production-ready over uhttpd's `/ubus/subscribe/` SSE path, replacing the
LuCI-controller stats route (which carries the ~1.1 KB padding hack and the `script_timeout`
reconnect machinery). Build the reusable foundation (daemon, procd, client lifecycle, ACL) so
**logs/top** can follow with little extra work.

**Out of scope — volume export stays on the worker+staging model** (`docs/plan-volume-export-api.md`).
SSE is text-only and its teardown is slow (see below); a stuck *export* would keep a multi-GB tar
operation alive 30–120 s+ after abandonment. Export leak-prevention belongs to the worker
(`timeout`-wrapped process + staging-file GC), not SSE.

## Facts established by prototyping on r4 (25.12)

- SSE writes are **not coalesced** and there is **no `script_timeout` hard cap** on this path.
- Only an idle `network_timeout` (~20 s) — but `uh_chunk_vprintf` **resets it on every write**, so a
  stream emitting more often than 20 s lives indefinitely. A heartbeat is only needed if a kind can
  go quiet > ~15 s; stats (3 s) never does.
- Auth: `Authorization: Bearer <sid>` only (no cookie/query), checked **once at subscribe**. ACL via
  `session.access {object, function:":subscribe"}`; rpcd matches object names with **fnmatch**
  (`podman_stats_*` works).
- A **raw** `conn.publish()` method called via HTTP `/ubus` must declare **`ubus_rpc_session`** in its
  `args` policy or it returns `[2]` INVALID_ARGUMENT.
- **No params on the subscribe URL** (verified in uhttpd `ubus.c`): the query string is stripped
  before routing (`strchr(url,'?')→'\0'`), the handler is GET-only (POST→404), no body is read, and
  `notify()` broadcasts to all subscribers (no per-subscriber channel). So the **object name is the
  only selector** → per-container objects (`podman_stats_<id>`) + wildcard ACL are required; params
  cannot replace them. The wildcard is safe (only the daemon creates these objects; subscribing to a
  never-published name just fails lookup).
- **Fan-out**: N subscribers to one object = 1 Podman stream. **GC** of idle objects works.
- **Session**: `session.access` (the subscribe-time ACL check) RENEWS the session timer (rpcd
  `rpc_touch_session`), but a continuous stream's notify traffic does not — so a held-open stream
  cannot keep a session alive (verified: a 15 s session expired under an active stream). A stream
  can outlive its (now-dead) session until the connection drops or the backstop fires.
- **Teardown latency: 31 s clean close, >120 s abrupt** (`kill -9`/crash/suspend). Root cause: the
  3 s notifications keep resetting uhttpd's idle timer, so dead-client detection falls back on TCP
  write-failure (kernel retransmit timeout) — slow and high-variance.
- **Exhaustion**: ~100 concurrent streams fill `uhttpd.max_connections=100` → **UI unreachable**;
  self-heals in ~35 s after slots free.
- **Keystone**: publisher `obj.remove()` → uhttpd `remove_cb` → `ops->request_done(cl)` →
  **the SSE connection is closed**. The daemon can therefore *actively* reclaim any stream.

## Architecture

One persistent ucode **daemon** publishes:
- a control object **`podman_stream`** with `ensure({kind, id, params})` → registers and returns the
  data object name (idempotent; resets that object's GC/lifetime clock). Params (interval; later
  tail/since/until/follow/...) ride on this call, NOT the subscribe URL (which can't carry them).
- per-stream data objects named **`podman_<kind>_<sha256(sid | kind | container | %J(params))[:24]>`**
  (ucode-mod-digest), each opening its **single-container** Podman stream only while subscribed.
  One object per DISTINCT stream is required because `notify()` broadcasts to ALL subscribers of an
  object — you cannot collapse to one topic per kind.
  - The hashed name is opaque + one-way (no session token / params leak), deterministic (reload →
    same name → reuse, no churn), and unguessable without the session id → de-facto per-session
    isolation even under the broad `podman_<kind>_*` wildcard ACL (kept; safe given opaque names).
  - Params are stored in daemon memory (to build the Podman URL); the session is only hashed,
    never stored. The Podman stream is started from the data object's SUBSCRIBE CALLBACK (not the
    2s sweep) so the first sample isn't delayed ~2s.

Supervision: a **procd service** (respawn). Started **on demand** by the client (see below), not at
boot — idles cheaply (~2 MB) once started, until reboot.

Client flow (in `Container.streamStatsViaSSE`):
1. `rpc podman.stream_ensure_daemon` — idempotent; starts the daemon if its control object is
   absent, waits until `podman_stream` is on the bus. (Fast no-op when already running.)
2. `rpc podman_stream.ensure {kind:'stats', id}` → object name.
3. `fetch('/ubus/subscribe/<name>', { headers:{ Authorization: 'Bearer '+L.env.sessionid }})`,
   read the event-stream, parse `data:` → `Stats[0]` → `onChunk`.
4. **Auto-reconnect** on any close (small backoff), re-running 1→3. Stop only on tab
   hidden/unload/destroy.

### Reclamation & session security — the corrected model
KEY FACT (verified in rpcd `session.c`): `session.access` — the ACL check uhttpd runs at every
subscribe — **RENEWS** the session timer (`rpc_session_get` → `rpc_touch_session`). So any
subscribe/ensure/reconnect renews the session. BUT a held-open stream's notification traffic is
**not** a client ubus call, so a **continuous** stream does **not** renew the session (verified:
a 15 s session expired while a stream was active). Design consequences:

- **No short/periodic recycle.** Frequent reconnects would renew the session → keep a forgotten
  session alive forever (the immortal-session hole). A **continuous** stream is the secure choice —
  it cannot immortalize the session; an idle session expires on its normal timer.
- **Clean abandonment** (tab close/switch/navigate/hidden): frontend stops the stream → closes in
  <1 s. Use `visibilitychange`(hidden) + `beforeunload` + view-destroy, not just tab-switch.
- **Abrupt abandonment** (crash/suspend/Wi-Fi drop, no JS): TCP write-failure detection reclaims it
  in ~30–120 s usually (fast path), but is unreliable — not the guarantee.
- **Single server-side backstop** = daemon `obj.remove()` after an interval **≈ `luci.sauth.sessiontime`**
  (read the existing config; never invent a value). Removal closes the SSE connection
  (`request_done`). Because the interval ≥ the session timeout:
  - a FORGOTTEN stream's session has already expired → the frontend's reconnect re-subscribe is
    **denied** → stream stays dead → user redirected to login ("canceled after session timeout +
    logged out");
  - it **cannot** immortalize a session — a recycle renews only when the session is still
    legitimately alive (kept alive by real user activity elsewhere); an idle session is gone before
    the backstop fires;
  - it also reclaims dead/crashed connections within ≤ sessiontime (hard server-side bound).
- **Connection cap** (below `uhttpd.max_connections`) protects the UI during the interim (the
  backstop is long, so the cap is the real exhaustion guard).
- **Frontend**: auto-reconnect on close (small backoff); on a **denied** re-subscribe (expired
  session) redirect to login (standard `catchError`). **Never poll the session to check liveness** —
  a poll is a `session.access` and would itself renew it (same trap).
- Trade-off (accepted): no short recycle means a crashed client's slot can linger up to ~sessiontime
  in the rare case TCP never detects it — slower reclamation, bought in exchange for **no
  immortal-session hole**. The cap prevents UI lockout meanwhile.

### Respecting `uhttpd.max_connections`
uhttpd enforces the limit but the failure mode (UI down) is unacceptable, so the daemon **caps its
own streams below it**, leaving headroom for normal LuCI. At startup read
`uhttpd.main.max_connections` (uci); cap active data objects at e.g. `floor(max_connections/2)`
(min 4), overridable via `podman.globals`. `ensure` returns an error past the cap; the frontend
surfaces "too many active streams". This is the explicit "respect existing config" requirement.

## Components to build

1. **Daemon** `root/usr/share/podman/stream-daemon.uc` (rename/generalize the prototype):
   control object + per-(kind,id) objects; `endpoint_for(kind,id)` (stats now; logs/top later);
   2 s sweep for start/stop/GC; per-object backstop `obj.remove()` at ≈ `luci.sauth.sessiontime`
   (NOT a short recycle); **error backoff / stop on permanent 4xx** (fixes the 2 s busy-retry);
   stream-count cap. Reuse `luci.podman_socket`,
   `luci.podman_http`, and **`luci.podman_validate`** (`validate_id`/kind whitelist) — do not
   hand-roll the id regex.
2. **procd init** `root/etc/init.d/podman-stream`: `USE_PROCD=1`, `start_service()` →
   `procd_open_instance` / `procd_set_param command /usr/bin/ucode <daemon>` /
   `procd_set_param respawn` / stdout+stderr to logd. Not enabled at boot (on-demand).
3. **rpcd method** `stream_ensure_daemon` in `podman.uc`: if pidfile/control-object absent →
   `init_action('podman-stream','start')` (from **`luci.sys`**, already used here), poll up to ~2 s
   for the `podman_stream` object, return status. No user input → injection-safe.
4. **ACL** (`acl.d/luci-app-podman.json`): `podman_stream:["ensure"]`, `podman_stats_*:[":subscribe"]`,
   `podman:["stream_ensure_daemon"]`. (Daemon's `ensure` policy already includes `ubus_rpc_session`.)
5. **Frontend** `model/Container.js`: rewrite `streamStatsViaSSE` to the ensure-daemon → ensure →
   subscribe → reconnect/backoff flow; handle the **denial case** (HTTP 200 + JSON error body →
   not `resp.ok`) and **session expiry** on re-subscribe (redirect to login like `catchError`).
   `container-tab/stats.js`: add stop-on-`visibilitychange`/unload in addition to `onTabInactive`.
6. **Makefile**: install the daemon + init script; **remove the test harness** (ssetest publisher,
   `view/podman/ssetest.js`, the `admin/podman/ssetest` menu entry, the `podman_ssetest` ACL grant).
7. **CLAUDE.md / docs**: add the deploy step (`/etc/init.d/podman-stream restart` after daemon
   changes) and the gotchas (ubus_rpc_session policy, max-lifetime).

## ucode-ubus implementation notes (verified vs docs + on r4)
- Use the explicit method form `{ name: { call: fn, args: {…} } }` — NOT the docs' shorthand
  `{ name: (req,msg)=>… }`. Only the explicit form declares the `args` **policy**, which we need for
  `ubus_rpc_session` (the `/ubus` `[2]` fix) and type validation. Proven working on r4.
- Handler is `call(request)`; read inputs from `request.args`; **return a plain object to reply**
  (no need for `request.reply()`). Proven.
- `obj.notify(type, data)` broadcasts to all subscribers (async, fire-and-forget). `obj.subscribed()`
  → bool. `obj.remove()` → `ubus_remove_object` (closes uhttpd SSE connections via `request_done`).
- **GC: retain references to `conn` AND every published object** (module scope / in the `streams`
  map / the control object). Dropping a reference lets ucode GC unregister the object out from under
  live subscribers. Make this an explicit invariant in the daemon.
- `connect()` default socket; its `timeout` (30 s) is per request/response op only — it does not
  affect the long-lived publish/notify/uloop path.

## Security / auth checklist
- AuthN: Bearer session on subscribe; ensure-daemon + ensure gated by the `luci-app-podman` ACL
  group (admin sessions only).
- AuthZ: explicit ACL grants above; `stream_ensure_daemon` under **write** (it starts a service).
- Input validation: daemon validates `kind` (whitelist) + `id` (`validate_id`) before composing the
  Podman path; the daemon never execs user input.
- DoS: stream-count cap (above) bounds slot/Podman pressure; max-lifetime bounds leaks.
- Isolation: the `podman_<kind>_*` wildcard is broad in theory, but object names are
  `sha256(session|kind|container|params)` — unguessable without the session token, so in practice a
  session can only derive/subscribe to its OWN streams. Not a hard ACL guarantee (consistent with
  LuCI's all-or-nothing admin model), but no cross-session data exposure via guessable names.
- Session: a continuous stream does NOT renew the session (verified), so a forgotten stream's
  session expires on normal inactivity — no immortal-session hole. The sessiontime-aligned backstop
  + reconnect-denial cancels the forgotten stream and logs the user out. Never poll the session to
  check it (poll = `session.access` = renewal).

## Performance traps to avoid
- Don't busy-retry on permanent errors (4xx) — back off / stop (the prototype hammered Podman every
  2 s on a 404).
- Stagger is automatic (per-object lifetime timers), but verify no global recycle tick.
- `notify()` re-serializes the sample; fine for stats, revisit for high-rate kinds.
- One Podman socket per *distinct* active stream; fan-out keeps same-container viewers at one.
- Logs (later) need 8-byte multiplexed frame de-framing (as the controller does) — more CPU/parse.

## What we skipped during testing (now required)
procd service · client-side daemon-start · **frontend auto-reconnect on unclean close** (prototype
just logged and stopped) · stop-on-hidden/unload · max-lifetime recycle · stream-count cap · error
backoff · use `podman_validate` not a hand-rolled regex · remove test harness · decide fate of the
old controller stats path · translations for new strings · Makefile install · lsp `@param` tidy.

## Open decisions (remaining)
1. **Daemon start model**: on-demand via client (recommended — matches "client starts it", no
   always-running daemon) vs enabled at boot. Both keep procd respawn.
2. **Keep the old controller stats route** as a UCI-flagged fallback during rollout, or replace
   outright?
3. **Stream-count cap fraction** of `max_connections` (default ½).

RESOLVED (this discussion): reclamation = **continuous stream + single backstop ≈
`luci.sauth.sessiontime` + connection cap; NO short recycle** — because `session.access` renews the
session, so a short recycle would immortalize a forgotten session. Continuous streams don't renew;
the sessiontime-aligned backstop reclaims leaks and cancels forgotten streams without that risk.

## Build sequence
1. Daemon (generalized, cap + max-lifetime + backoff, validate module) → 2. procd init →
3. rpcd `stream_ensure_daemon` + ACL → 4. deploy, retest ensure-daemon/start + recycle + cap →
5. frontend (reconnect + stop-on-hidden + denial/expiry) → 6. verify in browser (kill tab, sleep,
quick reconnect, cap) → 7. remove harness + Makefile + docs.
