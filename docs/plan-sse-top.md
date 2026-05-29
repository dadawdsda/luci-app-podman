# Plan: migrate container `top` (processes) to the SSE daemon

Status: **drafted, not implemented.** Builds directly on `docs/plan-sse-stats-production.md`
(the daemon, procd, rpcd `stream_ensure_daemon`, ACL pattern, hash naming, cap/backstop/backoff/
GC, subscribe-callback start, and the frontend ensure→subscribe→reconnect/auth flow are all reused
unchanged). This plan is only the **delta** for `top`.

## Why top is easy (and a good next step after stats)
- Like stats, libpod `/containers/{id}/top?stream=true` emits **NDJSON snapshots** — one JSON
  object per `delay` interval: `{ "Titles": [...], "Processes": [[...], ...] }`. So the daemon's
  existing per-line parser + `obj.notify(kind, sample)` works **as-is**; no new framing (logs will
  need 8-byte multiplexed de-framing — that's the hard one, later).
- It's the **first kind with a string param** (`ps_args`), so it exercises two foundation paths we
  built but haven't stressed: hash-naming with a non-numeric param (hashing handles it trivially)
  and **server-side sanitization of a string before it reaches the Podman URL**.

## Params (ride on `ensure`, as designed)
From the existing controller route, mirrored:
- `delay` — integer, **≥ 2** (libpod rejects faster); default 5.
- `ps_args` — optional string, validated `^[-a-zA-Z0-9_, ]+$` (the controller's regex); spaces
  URL-encoded to `%20` when composing the path. The restrictive regex is the injection guard.

## Changes

### Daemon `stream-daemon.uc`
1. `KINDS`: add `top: true`.
2. `normalize_params('top', params)` — build in **fixed key order** `{ delay, ps_args }`:
   - `delay = int(params.delay) || 5; if (delay < 2) delay = 2; if (delay > 60) delay = 60;`
   - `ps_args`: if present, must match `^[-a-zA-Z0-9_, ]+$` else return null (invalid) → ensure
     errors; normalize empty to `''`.
   - Return `{ delay, ps_args }` (both keys always, so `%J` is stable for the hash).
3. `endpoint_for('top', id, params)`:
   `sprintf('%s/containers/%s/top?stream=true&delay=%d', API_BASE, id, params.delay)`, then if
   `params.ps_args` append `&ps_args=` + `replace(params.ps_args, / /g, '%20')`.
   (No new imports — same trick the controller used; regex already restricts to safe chars.)

That's the whole daemon delta — parsing, notify, lifecycle, naming, cap, backstop are unchanged.

### ACL `acl.d/luci-app-podman.json`
- Add `"podman_top_*": [":subscribe"]` under `read.ubus` (same wildcard pattern as
  `podman_stats_*`; opaque session-hashed names keep it effectively per-session).

### Frontend
1. `model/Container.js`: add `streamTopViaSSE(onChunk, delay, psArgs)` — a near-copy of
   `streamStatsViaSSE`, differing only in:
   - `ContainerRPC.streamEnsure('top', id, { delay: delay || 5, ps_args: psArgs || '' })`;
   - `onChunk(sample)` **directly** (top samples are `{Titles, Processes}`, not wrapped in an
     array like stats' `Stats[0]`); skip samples with `.Error`/`.raw`.
   - Consider extracting the shared connect/reconnect/auth machinery into one private helper
     (`_subscribeStream(kind, params, onSample)`) that both stats and top call, to avoid
     duplicating the ~60 lines. (Do this when adding top, since it's the second consumer.)
2. `view/podman/container-tab/processes.js`: switch `onTabActive` from `streamTop(...)` to
   `streamTopViaSSE(...)`, and add the same **stop-on-`visibilitychange` + `beforeunload`**
   lifecycle that `stats.js` got (factor that into a tiny shared mixin/helper if convenient).

No backend parsing/route work, no menu changes (the data path is the daemon + uhttpd; no new LuCI
route).

## Test plan (on r4, mirrors the stats checks)
- `ensure('top', id, {delay:5, ps_args:''})` → opaque `podman_top_<hash>`; subscribe → samples with
  `Titles`/`Processes`.
- `ps_args:'-eo pid,comm'` (valid) → streams; the hash name differs from the no-args one.
- `ps_args:'bad;rm -rf'` → ensure returns `invalid params` (regex rejects).
- `delay:1` → clamped to 2; `delay:'x'` → default 5.
- Same session+params twice → same name (reuse); different session → different name.
- Browser: Processes tab streams live; pause-on-hidden works; running-container guard intact.

## Follow-ons (note, not this round)
- **`pod_top`** is the same pattern, even simpler (kind `pod_top`, id = pod name,
  `/pods/{name}/top?stream=true&delay=`, no `ps_args`) — for the pod detail processes view.
- **Finalization is still deferred**: keep the old `stream/top` (and `stream/stats`) controller
  routes as fallback until **stats + top + logs + pull** are all on SSE, then remove the controller
  streaming + `stream/*` menu entries + old `streamX` methods + test harness **wholesale** (one
  finalization pass, not piecemeal — avoids touching the controller repeatedly and keeps a fallback
  during the migration).
- **logs** is the genuinely hard kind (8-byte stdout/stderr frame headers to de-frame in the
  daemon; `since`/`tail`/`follow` params; reconnect-resume semantics) — plan that separately.
