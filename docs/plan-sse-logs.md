# Plan: migrate ALL container logs (live + one-shot) to SSE

Status: **drafted, not implemented.** Builds on `docs/plan-sse-stats-production.md` +
`docs/plan-sse-top.md` (daemon, procd, rpcd ensure-daemon, hash naming, cap/backstop/backoff/GC,
subscribe-callback start, `_subscribeStream` helper — all reused). This is the delta.

## Scope: unify BOTH log modes on the daemon
- **Live / follow** (`follow=true`, running container): unbounded tail; auto-reconnect + resume;
  backstop applies.
- **One-shot / historical** (`follow=false`: a `tail`/`since`/`until`-bounded query, e.g. the user
  stops the live stream and fetches a fixed window — including on a *running* container): the daemon
  opens the bounded query, streams the result, and on Podman **EOF emits `{done:true}` and removes
  the object** → the SSE connection closes. The client renders the lines and **does not
  auto-reconnect**.

Unifying both means the controller `container_logs` route is **removed** in the finalization (logs is
no longer an exception), and big historical windows stop being `script_timeout`-bound (the SSE path
has no hard cap).

## Why logs is the hard kind
1. **Not NDJSON** — non-TTY containers multiplex stdout/stderr with **8-byte frame headers**
   (`!BxxxI`: stream_type byte + 3 pad + uint32 length); TTY containers send **raw** bytes. Needs a
   different parser (`struct.unpack`) and must know TTY-ness.
2. **Text, not JSON** — de-framed text is wrapped in a notify object.
3. **Reconnect-resume** (live) — resume from the disconnect point, not a `tail` re-dump.
4. **One-shot done/close handshake** — a `{done}` sentinel so the client knows "complete" vs
   "dropped".
5. **Volume** — chunk-based notify (batches a read's worth of lines; **loses nothing** — the client
   splits the chunk back into exact lines; just fewer notifies under bursts).

## Daemon changes (`stream-daemon.uc`)
1. `KINDS += { logs: true }`; `import * as struct from 'struct';` (ucode-mod-struct, already a dep).
2. **Per-kind parser** — `on_readable` dispatches to `e.parse(e)`:
   - `parse_ndjson` (stats/top) — current line split.
   - `parse_logs` — if `e.params.tty`: emit `rbuf` as `{ raw: rbuf }`, clear it (raw passthrough).
     Else de-frame (mirror the controller `framebuf` loop: `struct.unpack('!BxxxI', substr(rbuf,0,8))`,
     wait for the full payload, **merge** stdout(1)+stderr(2) payloads), then
     `notify('logs', { raw: <de-framed chunk> })`; a partial trailing frame stays in `rbuf`.
3. `normalize_params('logs', params)` — fixed key order `{ tail, since, until, follow, tty }`:
   `tail` int 1..1000 or `'all'` (default 100); `since`/`until` unix secs (0 = unset); `follow` bool;
   `tty` bool (from the frontend's inspect).
4. `endpoint_for('logs', id, params)`:
   `/containers/<id>/logs?follow=<follow>&stdout=true&stderr=true&timestamps=false&tail=<n>`
   (+ `&since=`/`&until=` when set).
5. **Live (`follow=true`) resume**: entry `started_once` + `resume_since`. `start_stream`: if
   `started_once` → `since=resume_since`, drop `tail`; else original `tail`/`since`, set the flag.
   `stop_stream`: `resume_since = time()`. Backstop applies (it's unbounded).
6. **One-shot (`follow=false`)**: on Podman EOF (empty recv) → `notify('logs', { done: true })` →
   stop + `remove` the object. **Exempt from the backstop and from resume** (bounded; it terminates
   on its own — no indefinite leak even if the client vanishes mid-fetch).
7. **TTY**: choose framed vs raw by `e.params.tty` (authoritative; the frontend passes it). Content
   sniffing is only a heuristic (raw can look framed) — not used.

## ACL
- add `"podman_logs_*": [":subscribe"]`.

## Frontend
1. **`_subscribeStream(kind, params, onSample, opts)`** gains:
   - recognizes a `{ done: true }` sample → marks the close as a clean completion;
   - `opts.oneShot` → after the connection closes (whether via `{done}` or a drop), **stop; never
     reconnect** (and don't treat it as an auth failure). Live mode is unchanged (auto-reconnect).
2. **`Container.streamLogsViaSSE(onLine, { tail, since, until, follow, tty })`** →
   `_subscribeStream('logs', { tail, since, until, follow, tty }, onSample, { oneShot: !follow })`.
   `onSample`: ignore `{done}`; else split `{ raw: chunk }` on `\n` (partial-line buffer across
   samples) → `onLine({ raw: line })`. `logs.js`'s per-line handler is unchanged.
3. **`container-tab/logs.js`**:
   - route the live path (running → follow) and the one-shot path (stopped, or user "fetch once" →
     `follow:false`) both through `streamLogsViaSSE`, passing `tty: this.container.getTty()`. (The
     existing controller `streamLogs` call is dropped.)
   - **Auto-stop on hidden tab** with intent tracking: keep `_wantStream` (true on play / live
     auto-start, false on user Stop). `visibilitychange`: hidden → stop (keep `_wantStream`); show →
     if `_wantStream`, restart (live resumes via `resume_since`, filling the gap). A completed
     one-shot sets `_wantStream=false` (no resume). Explicit Stop is never auto-resumed.

## Finalization (updated)
The `container_logs` controller route is now **removable** — both modes run on the daemon. So the
wholesale finalization removes the stats/top/logs/pull controller stream routes + their `stream/*`
menu entries + the old `streamX` methods + the test harness. (Logs is no longer the exception.)

## Test plan (on r4)
- Live non-TTY: stdout+stderr merged, in order; high-volume burst keeps up; reconnect/backstop
  resumes from disconnect (no `tail` re-dump, ≤ ~1 s boundary overlap).
- TTY container (`tty:true`): raw passthrough, no garbled frame bytes.
- One-shot (stopped container, `tail=200`): streams the window, gets `{done}`, closes, **no
  reconnect**.
- One-shot large window: completes with no timeout (SSE path has no `script_timeout`).
- Hidden tab: live pauses then resumes (gap filled); a user-Stopped stream is **not** auto-resumed.
- Same (session, container, params) → reused object; different `tail`/`since`/`follow` → new object.

## Resolved decisions
chunk-based notify (lossless); `tty` passed from the frontend; stdout+stderr **merged**; auto-stop on
hidden = **yes** (with intent tracking); historical **unified** as a one-shot (`{done}` + close, no
client auto-restart).

## Follow-on
**pull** (keyed by image reference; resume-by-byte-offset; has a worker today) — separate plan. Then
the wholesale finalization above.
