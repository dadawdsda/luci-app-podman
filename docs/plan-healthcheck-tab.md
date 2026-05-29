# Plan: Healthcheck tab in container details

Status: **drafted, not yet implemented**
Scope: **frontend only** — the backend already supports everything (see below).

Resolves TODO items:
- Container → List → Details → "Healthcheck tab with form and manual health check action"
- Container → Add → "Missing health check settings" (partially — this is the *details* tab; the
  create form is a separate follow-up that can reuse the same field set)

## Key finding: the backend is already complete

- **Set options:** `POST /libpod/containers/{name}/update` (body schema `UpdateEntities`,
  swagger:15414/11215) accepts every `health_*` field. `podman_validate.uc` `BODY_KEYS` already
  whitelists all of them, so `container_update` (rpcd `podman.uc:280`) passes a health-only body
  straight through. No backend change.
- **Run it:** `container_healthcheck_run` (`GET /containers/{id}/healthcheck`, rpcd
  `podman.uc:319`) already exists and is in the ACL (read + write).
- `container.js:57` already has a commented-out `// .addTab('health', _('Health'))`.

So: **no changes to rpcd, ACL, menu.d, or Makefile.**

## Update-body field names (UpdateEntities, snake_case)

Primary healthcheck:
- `health_cmd` (string; plain string is wrapped CMD-SHELL by Podman; `"none"` disables)
- `health_interval` (duration string e.g. `30s`; `disable` = no timer)
- `health_timeout` (duration string)
- `health_start_period` (duration string)
- `health_retries` (uint)
- `health_on_failure` (string: `none` | `kill` | `restart` | `stop`)

Startup healthcheck (advanced):
- `health_startup_cmd`, `health_startup_interval`, `health_startup_timeout`,
  `health_startup_retries`, `health_startup_success`

Logging (advanced):
- `health_log_destination` (string: `local` | `events_logger` | directory path)
- `health_max_log_count` (uint), `health_max_log_size` (uint)

## Reading current values (inspect → form defaults)

From `container.inspect()` (already fetched into `container.js this.data`):
- `Config.Healthcheck` = `Schema2HealthConfig`: `Test[]`, `Interval`, `Timeout`, `StartPeriod`,
  `StartInterval`, `Retries` — **durations are nanoseconds (int)**.
- `Config.StartupHealthCheck` = `StartupHealthCheck`: `Test[]`, `Interval`, `Timeout`,
  `StartPeriod`, `Retries`, `Successes`.
- `Config.HealthcheckOnFailureAction` (string in inspect output, default `none`).
- `Config.HealthLogDestination`, `Config.HealthcheckMaxLogCount`, `Config.HealthcheckMaxLogSize`.

Current status from `State.Health` (`Health` def, swagger:2282): `Status`
(none/starting/healthy/unhealthy), `FailingStreak`, `Log[]` (`HealthcheckResult`: `Start`,
`End`, `ExitCode`, `Output`).

### Converters needed (add to `podman/utils.js` — check there first, don't duplicate)
- `nsToDuration(ns)` → `"30s"` / `"1m30s"` for field defaults (inspect ns → update string).
- `parseHealthTest(test[])` → command string: empty if `!test.length` or `test[0]==='NONE'`;
  `test.slice(1).join(' ')` for `CMD-SHELL`/`CMD`; else `test.join(' ')`.

## Components (all frontend)

### 1. `podman/form/healthcheck.js` (new) — mirrors `form/resource.js`
- `podmanView.form.extend`, `makeData()` reads inspect (with the converters above),
  `render(container)`, `createForm()` builds the fields, `handleUpdate()`.
- Primary fields always visible; startup + logging fields in a secondary/advanced group
  (e.g. a second `form.Section` or below a visual separator). **Confirm grouping with user.**
- Duration fields: `form.Value` with a duration-string validator (`/^(\d+(\.\d+)?(ns|us|ms|s|m|h))+$/`)
  and placeholders (`30s`).
- `health_on_failure`: `form.ListValue` (none/kill/restart/stop).
- `_update` `form.Button` ("Update Healthcheck") → `handleUpdate()`.
- Optional "Disable healthcheck" → sends `{ health_cmd: 'none' }`.
- `handleUpdate()` builds a body of only the changed/relevant `health_*` keys and calls
  `this.container.updateHealthcheck(data)` (NOT `update()` — see trap below), then
  `super('handleCreate', [...])` for the loading/success UX like `resource.js:111`.

### 2. `view/podman/container-tab/health.js` (new) — `podmanView.tabContent`
- `render(container)`: status panel (Status badge + FailingStreak + latest `Log` entries as a
  small `podmanUI.Table` of Start/ExitCode/Output) + a **"Run Healthcheck"** button + the
  embedded settings form (`await new PodmanFormHealthcheck.init().render(container)`).
- Gate the Run button: enabled only when `container.isRunning() && container.hasHealthcheck()`;
  otherwise render a hint (`warningContent`, like `processes.js:15`). The run endpoint returns
  409 if no healthcheck / not running.
- Run handler → `container.runHealthcheck()` → re-inspect → re-render the status panel.

### 3. `podman/model/Container.js` (edit)
- Add to `ContainerRPC`: `healthcheckRun: Model.declareRPC({ object:'podman',
  method:'container_healthcheck_run', params:['id'] })`. (Per-action RPCs live in `ContainerRPC`
  here, not `rpc.js` — consistent with `start`/`stop`/`update`.)
- Add methods:
  - `async updateHealthcheck(data) { return ContainerRPC.update(this.getID(), data); }`
    — thin wrapper that **skips** the init-script reconciliation in `update()`.
  - `async runHealthcheck() { return ContainerRPC.healthcheckRun(this.getID()); }`
  - `getHealth() { return this.State?.Health || null; }`
  - `hasHealthcheck()` → true if `Config.Healthcheck.Test` is non-empty and not `["NONE"]`.

### 4. `view/podman/container.js` (edit)
- `'require view.podman.container-tab.health as ContainerHealthTab';`
- Uncomment/keep `.addTab('health', _('Health'))` (current slot is between logs and inspect;
  placement adjustable — could sit next to Resources since both are config).
- Add `this.renderHealthTab();` in the `requestAnimationFrame` block and:
  `async renderHealthTab() { this.renderTab('health', await ContainerHealthTab.render(this.container)); }`

## The `update()` init-script trap (why a dedicated wrapper)
`Container.update()` (`Container.js:523`) does init-script reconciliation off
`data.RestartPolicy`; with a health-only body `policy` is `undefined` and `undefined !== 'no'`
is **true**, which could spuriously generate an init script on containers without a restart
policy. Health config is unrelated to autostart, so `updateHealthcheck()` calls
`ContainerRPC.update()` directly and skips that logic. (Resource updates share this latent
quirk — noted, not fixed here.)

## Gotchas / verify before coding (owrt-dev + luci-javascript-guidelines)
- Confirm `form.ListValue` / `form.Value` / `form.Button` / `form.Section` usage against the
  jsapi docs via owrt MCP (the skill mandates checking even "obvious" APIs).
- All user-visible strings through `_()`; run `audit_translations` after (owrt MCP, not
  update-pot.sh).
- ns↔duration round-trip: don't lose precision; `0`/unset → empty field (means "inherit").
- Re-inspect after Run rather than trusting only the returned result, so the status panel and
  `hasHealthcheck()` reflect reality.

## Open decision for the user
- **Field scope/grouping:** expose the full set (primary + startup + logging, grouped) vs. a
  primary-only v1 (command/interval/timeout/retries/start-period/on-failure) with startup &
  logging deferred. Default in this plan: full set, grouped (primary visible, advanced below).

## Follow-up (separate, not this round)
- Add the same health field set to the container **create** form (TODO: Container → Add →
  "Missing health check settings") — reuse `form/healthcheck.js` field definitions if practical.
