# Maintenance Mode — Operations Runbook

> TASK-090 OQ-4 / SRS FR-019. Owner: platform on-call.
> Source code: `app/middleware/maintenance_mode.rb`,
> `app/controllers/api/v1/health/maintenance_controller.rb`,
> `config/initializers/maintenance_mode.rb`.

## What it does

When `MAINTENANCE_MODE_ACTIVE=true`:

- All `/api/v1/*` requests return **HTTP 503** with this JSON body (the SRS
  FR-019 / §10A contract — the Chrome extension routes on `apiErrorCode`
  ← `error`, and Frame19's countdown reads `retry_after_minutes`):
  ```json
  {
    "maintenance": true,
    "error": "MAINTENANCE_MODE",
    "until": "2026-06-01T12:00:00Z",
    "until_unix": 1780315200,
    "retry_after_seconds": 60,
    "retry_after_minutes": 1,
    "message": "Системные работы. Возвращаемся скоро."
  }
  ```
  plus HTTP headers `Retry-After: <seconds>` and `Cache-Control: no-store`.
  `retry_after_minutes` = `ceil(retry_after_seconds / 60)`.
- The frontend (Chrome Extension side panel) detects this body and renders a
  maintenance banner instead of generic "network error" toasts.
- `GET /api/v1/health/maintenance` **stays accessible** (HTTP 200) so the
  frontend can poll for the start/end of the window. While maintenance is ON
  its body is **identical** to the 503 body above (incl. `error` and
  `retry_after_minutes`); while OFF it returns `{"maintenance": false,
  "status": "ok"}` (no `error` field). The 200 response is sent with
  `Cache-Control: no-store` so a CDN/proxy can't serve a stale state to the
  ~30s poller.
- `GET /up` (Rails / Kamal proxy health probe) **stays accessible** so Kamal
  rolling deploys and load-balancer health checks continue to work.
- All other paths outside `/api/v1/*` are untouched — webhooks
  (`/webhooks/twitch`), Action Cable (`/cable`), Flipper UI (`/admin/flipper`),
  and the Rails health endpoint (`/health`) are not blocked.

The middleware runs **before** `Rack::Attack`, so blocked requests do not
count toward rate-limit buckets.

## ENV variables

| Variable                      | Type    | Default | Notes                                                                                                  |
| ----------------------------- | ------- | ------- | ------------------------------------------------------------------------------------------------------ |
| `MAINTENANCE_MODE_ACTIVE`     | boolean | `false` | Truthy values per `ActiveModel::Type::Boolean` — `"true"`, `"1"`, `"yes"`, `"on"`.                     |
| `MAINTENANCE_MODE_UNTIL`      | string  | unset   | ISO 8601 datetime, e.g. `2026-06-01T12:00:00Z`. Drives `until` / `until_unix` / `Retry-After` / `retry_after_minutes`. |
| `MAINTENANCE_MODE_MESSAGE`    | string  | i18n    | Generic message override — used for any locale that has no locale-specific override (see below).        |
| `MAINTENANCE_MODE_MESSAGE_EN` | string  | —       | EN-only message override. Wins over `MAINTENANCE_MODE_MESSAGE` when the resolved locale is `:en`.       |
| `MAINTENANCE_MODE_MESSAGE_RU` | string  | —       | RU-only message override. Wins over `MAINTENANCE_MODE_MESSAGE` when the resolved locale is `:ru`.       |

Message resolution per request: `MAINTENANCE_MODE_MESSAGE_<UPCASE-LOCALE>` →
`MAINTENANCE_MODE_MESSAGE` → i18n `api.maintenance.message` (`en`/`ru`).

If `MAINTENANCE_MODE_UNTIL` is malformed, unset, or in the past, `Retry-After`
defaults to **60 seconds** and `until` / `until_unix` / `retry_after_minutes`
are derived from it (`now + retry_after_seconds`) — they are **never `null`**,
because the Chrome extension only treats a response as "maintenance" when
`until` is a non-null ISO 8601 string. A warning is logged once per request on
invalid input — fix the env var or remove it.

> The body uses a flat `error: "MAINTENANCE_MODE"` string (the apiErrorCode the
> extension routes on) — distinct from the nested `{ error: { code, message, … } }`
> envelope used by Pundit/auth errors. `maintenance: true` is kept as a redundant
> boolean discriminator for the OQ-4 / extension-PR-#37 contract.

## When to use

1. **Kamal rolling deploys with heavy migration** — when a migration is
   long-running and you want to surface a clean UX to extension users instead
   of intermittent 5xx / timeouts during the rollout.
2. **Schema migrations that briefly lock tables** — set 5–10 min `UNTIL`
   buffer, run migration, flip off when complete.
3. **Third-party outage** (Twitch API down, postgres failover) — flip on
   while you triage; clients show a friendly banner.
4. **Emergency** — incident response toggle while you debug. Default
   `Retry-After=60` keeps clients polling and they recover automatically.

**Do NOT** use this for partial degradations (one slow endpoint). Use Flipper
feature flags for fine-grained shutoffs.

## How to flip the flag

### Option A — runtime ENV (no redeploy), per-destination

This is the fastest path and the one used for unplanned incidents. It uses
Kamal's `env push` to update the env file on the host and `app boot` to restart
containers with the new env. The container image itself does not change.

```bash
# Edit .kamal/secrets locally OR push a one-off override:
kamal app exec --reuse 'env | grep MAINTENANCE_MODE'   # current state
# then either edit `.env.production` / `.env.staging` and:
kamal env push -d staging
kamal app boot -d staging                               # rolling restart, picks up env

# Verify
curl -i https://staging.himrate.com/api/v1/health/maintenance
# → 200 + Cache-Control: no-store + {"maintenance":true,"error":"MAINTENANCE_MODE",...}
curl -i https://staging.himrate.com/api/v1/channels/123
# → 503 + Retry-After + Cache-Control: no-store + JSON
```

To flip off:

```bash
# Set MAINTENANCE_MODE_ACTIVE=false in the env file
kamal env push -d staging
kamal app boot -d staging
```

### Option B — deploy.yml (planned maintenance, version-controlled)

Add the three vars to `config/deploy.yml` under `env.clear:` (they are not
secrets — they describe state, not credentials):

```yaml
env:
  clear:
    RAILS_LOG_TO_STDOUT: true
    RAILS_SERVE_STATIC_FILES: true
    WEB_CONCURRENCY: 2
    MAINTENANCE_MODE_ACTIVE: true
    MAINTENANCE_MODE_UNTIL: "2026-06-01T12:00:00Z"
```

Commit, deploy via the normal pipeline (`git push origin main` → CI runs
`kamal deploy -d staging`), revert the commit + redeploy to flip off.

Option A is preferable for unplanned maintenance — it doesn't require a CI
round-trip. Option B is preferable for planned maintenance because it leaves
an audit trail in git.

### Choosing `MAINTENANCE_MODE_UNTIL`

- Set to **the end of the expected window + a small buffer** (e.g. 5 min).
- Use UTC ISO 8601 with the trailing `Z` — e.g. `2026-06-01T12:00:00Z`.
- The frontend uses `retry_after_minutes` / `until_unix` to render a countdown
  ("back in ~4 min" — Frame19 ICU-plural on minutes).
- If the actual maintenance overruns: bump the env var and `kamal app boot`
  again. Clients pick up the new `Retry-After` on their next poll (max
  60 seconds lag if no `UNTIL` was set).

### Choosing the message

- Russian default (no override): `"Системные работы. Возвращаемся скоро."`
- English default (no override): `"Scheduled maintenance. Back shortly."`
- Locale is detected per-request from `?lang=` query param (wins), then the
  `Accept-Language` header (q-value aware), else `I18n.default_locale` (`:en`).
- For incident-specific messaging set an override. Resolution order:
  `MAINTENANCE_MODE_MESSAGE_<UPCASE-LOCALE>` → `MAINTENANCE_MODE_MESSAGE` →
  i18n default. Use the locale-specific vars for a properly localized banner,
  or just `MAINTENANCE_MODE_MESSAGE` if you only have one string. Example:
  ```
  MAINTENANCE_MODE_MESSAGE_EN="Migrating database. ETA 5 min. status.himrate.com"
  MAINTENANCE_MODE_MESSAGE_RU="Миграция базы. ETA 5 мин. status.himrate.com"
  ```

## Smoke checklist (after flipping)

```bash
# 1. /up still healthy (load balancer / Kamal proxy)
curl -i https://staging.himrate.com/up
# → 200

# 2. Polling endpoint reports maintenance: true
curl -i https://staging.himrate.com/api/v1/health/maintenance
# → 200 + Cache-Control: no-store
#   + {"maintenance":true,"error":"MAINTENANCE_MODE","retry_after_seconds":60,"retry_after_minutes":1,...}

# 3. Real API endpoint is blocked
curl -i https://staging.himrate.com/api/v1/channels/123 -H "Authorization: Bearer xxx"
# → 503 + Retry-After: 60 + Cache-Control: no-store + JSON (same body shape as #2)

# 4. Locale switching
curl -s https://staging.himrate.com/api/v1/channels/123 \
  -H "Authorization: Bearer xxx" -H "Accept-Language: ru" | jq .message
# → "Системные работы. Возвращаемся скоро."

# 5. Webhooks unaffected (Twitch EventSub keeps working)
curl -X POST https://staging.himrate.com/webhooks/twitch -d '{}' \
  -H "Content-Type: application/json"
# → 400/401 (whatever the webhook controller normally returns), NOT 503
```

After flipping **off**, repeat #3 — it should return the controller's normal
response (200 / 401 / 404 depending on auth).

## Logging

Every blocked request logs at INFO:

```
MaintenanceMode: blocked path=/api/v1/channels/123 ip=1.2.3.4 method=GET ua="Mozilla/5.0 ..."
```

Use this to size the impact during an incident postmortem (request count by
path, distinct IPs, etc.). Goes to the regular Rails log → Loki via Promtail.
