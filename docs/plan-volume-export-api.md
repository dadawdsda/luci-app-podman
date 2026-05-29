# Plan: API-based volume export via a streaming worker

Status: **approved, not yet implemented**
Scope this round: **export only** (import is a separate later round — see bottom).

Resolves TODO items:
- Common → "Get rid of podman-api helper for volumes"
- Volumes → List → "Big exports which take more than 50s are failing"

## Background / root cause

Volume export today: frontend calls `fs.exec_direct('/usr/libexec/podman-api', ['volume_export', name], 'blob')`
→ `cgi-io exec` → the `podman-api` helper shells out to the `podman` **CLI** and pipes the tar to stdout.

Large exports fail because **`uhttpd` `script_timeout` is a hard wall-clock cap on a single
request** (default ~60s), *not* an idle timeout — continuous output does not save you. This is
the same constraint the controller's `session_timer` machinery already works around for
logs/stats/pull: no single request outlives `script_timeout`; long-livedness comes from the
**client reconnecting** and the server **resuming by a saved offset**.

Streaming-in-ucode alone does NOT fix this — constant-memory streaming is exactly what the CLI
export does now, and it's what times out. Fixing it requires **decoupling** the slow Podman
operation (a detached worker) from the <60s HTTP request, and bridging a *binary* download
across reconnects by **byte offset**, which requires the bytes to live in a re-readable
**staging artifact**.

The libpod API supports this: `GET /libpod/volumes/{name}/export` streams `application/x-tar`
(confirmed in `docs/swagger-latest.yaml:18100`). So the CLI is not required — the helper can be
removed entirely.

## Why reuse the pull-worker pattern

The pull machinery (detached worker → growing staging file → byte offset → reconnect → resume)
maps almost verbatim onto a binary download. The frontend just accumulates bytes into a `Blob`
instead of rendering NDJSON. Only real cost: a transient full-tar staging file, mitigated by a
UCI-configurable path.

## Confirmed design decisions

- **Reuse pull-worker + offset** machinery (generalize, don't rewrite).
- **Frontend-provided offset** (`?offset=N` query param), NOT session-stored like pull. The
  assembled `Blob` lives in the tab's JS memory, so surviving a closed tab is pointless for
  export — simpler and correct to let the client pass the offset on each reconnect.
- **No padding.** The 1500-byte space-pad keepalive corrupts binary. Export streams
  continuously, so on starvation/deadline we end the request and let the client reconnect
  instead of padding. Final sub-flush-threshold bytes flush on connection close (request end).
- **Completion via a separate ubus status method**, because the tar has no in-band "done"
  marker (any sentinel would corrupt it).

## Components

### 1. Worker — generalize `root/usr/share/podman/pull-worker.uc`
Add an `export` mode (or a shared `stream-worker.uc`). For export it:
- connects the socket, sends `GET {API_BASE}/volumes/{name}/export`
- parses response headers via `read_headers` / `parse_status` (`podman_http`)
- copies the **raw tar body** chunk-by-chunk (one `BLOCKSIZE` at a time, constant memory) into
  `staging/<id>.tar`
- on clean EOF → write `staging/<id>.done` containing the final byte size
- on non-200 → write `staging/<id>.err` containing the message
- removes its pidfile on exit (same lifecycle as the pull worker)

### 2. Controller stream route — `admin/podman/stream/volume_export/{id}`
Add to `menu.d/luci-app-podman.json` + `ucode/controller/podman.uc`. It:
- spawns the worker if not already running for that id
- reads `?offset=N`, seeks the staging file to N, streams `[N..current_size]` as raw bytes
- ends on deadline/starvation (client reconnects with a new offset)
- sets `Content-Type: application/x-tar`; **does not pad**

### 3. ubus methods (rpcd plugin `root/usr/share/rpcd/ucode/podman.uc`)
- `volume_export_status` → `{running, size, done, error}` for an id (frontend calls after stream
  close to distinguish *done* from *deadline-hit/reconnect*).
- `volume_export_cleanup` → unlink staging files once the client has the full blob
  (explicit/frontend-driven, avoids auto-delete race).

### 4. Frontend
- `model/Image.js`-style `_stream` variant (or a shared helper) that appends each chunk to a
  byte array and reconnects with `?offset=<bytesReceived>`.
- `view/podman/volumes.js handleExport`: reconnect loop; on close call status:
  - `error` → `podmanUI.alert`
  - `done && received == size` → build `Blob` → `<a download>` → `cleanup()`
  - else → reconnect with the new offset
  - sequential across multiple selected volumes, progress modal (bytes/total)

### 5. UCI staging path
New option e.g. `podman.globals.export_path` (default `/tmp`; document: set a disk-backed path
for volumes larger than free RAM, since `/tmp` is tmpfs/RAM on OpenWrt). Used by worker +
stream + status + cleanup. Add to `root/etc/config/luci-podman-opkg` and README.

### 6. Removals (podman-api goes away entirely)
`volume_export` moves to the API and the helper's `volume_import` action is already dead code
(import uses the ubus `volume_import` method + `/tmp/podman-import`). So delete:
- `root/usr/libexec/podman-api`
- its `cgi-io exec` + `file` entries in `root/usr/share/rpcd/acl.d/luci-app-podman.json`
- the `podman_api_helper` check in `system_debug` (rpcd plugin)
- its install line in `Makefile`

Import keeps working untouched this round.

## Completion protocol

```
worker:   socket GET /export ──chunk──► staging/<id>.tar   (constant mem)
          on EOF  → write staging/<id>.done = <size>
          on !200 → write staging/<id>.err  = <message>
stream:   GET .../volume_export/<id>?offset=N → seek N, write [N..size], end at deadline
client:   loop { read+append; on close → status() }
          status.error             → alert
          status.done && got==size → Blob → download → cleanup()
          else                     → reconnect with ?offset=got
```

## Verify against the owrt MCP before writing code (per owrt-dev skill)
- `http.write` is binary-safe for the tar body; how to set `Content-Type: application/x-tar`
  on the stream route. (The existing CLI export proves ucode `print()` of binary works, so this
  is low-risk — confirm anyway.)
- `fs` `open`/`seek`/`read` at an offset on the growing staging file (pull endpoint already
  does this).
- Sanitize the staging `<id>` derived from the volume name; validate `offset` against file size.

## Deferred: import round (separate change)
- Move import off the CLI to `POST /libpod/volumes/{name}/import` (uncompressed tar body).
- **Decompress `.tar.gz` server-side using the ucode zlib module**
  (https://ucode.mein.io/module-zlib.html) — decided, not browser-side.
- Big imports likely hit the rpcd timeout the same way → probably needs the same worker
  decoupling for parity.
