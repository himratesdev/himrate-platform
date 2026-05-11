# Maintenance Mode — Operations Runbook

> TASK-090 OQ-4. Owner: platform on-call.
> Source code: `app/middleware/maintenance_mode.rb`,
> `app/controllers/api/v1/health/maintenance_controller.rb`,
> `config/initializers/maintenance_mode.rb`.

## What it does

When `MAINTENANCE_MODE_ACTIVE=true`:

- All `/api/v1/*` requests return **HTTP 503** with a JSON body:
  ```json
  {
    "maintenance": true,
    "until": "2026-05-12T20:30:00Z",
    "until_unix": 1747083000,
    "message": "Системные работы. Возвращаемся скоро.",
    "retry_after_seconds": 60
  }
  ```
  and an HTTP `Retry-After` header (seconds).
- The frontend (Chrome Extension side panel) detects `maintenance: true` and
  renders a banner instead of generic "network error" toasts.
- `GET /api/v1/health/maintenance` **stays accessible** (HTTP 200) so the
  frontend can poll for the end of the window.
- `GET /up` (Rails / Kamal proxy health probe) **stays accessible** so Kamal
  rolling deploys and load-balancer health checks continue to work.
- All other paths outside `/api/v1/*` are untouched — webhooks
  (`/webhooks/twitch`), Action Cable (`/cable`), Flipper UI (`/admin/flipper`),
  and the Rails health endpoint (`/health`) are not blocked.

The middleware runs **before** `Rack::Attack`, so blocked requests do not
count toward rate-limit buckets.

## ENV variables

| Variable                   | Type    | Default | Notes                                                                                          |
| -------------------------- | ------- | ------- | ---------------------------------------------------------------------------------------------- |
| `MAINTENANCE_MODE_ACTIVE`  | boolean | `false` | Truthy values per `ActiveModel::Type::Boolean` — `"true"`, `"1"`, `"yes"`, `"on"`.             |
| `MAINTENANCE_MODE_UNTIL`   | string  | unset   | ISO 8601 datetime (e.g. `2026-05-12T20:30:00Z`). Drives `until` / `until_unix` / `Retry-After`. |
| `MAINTENANCE_MODE_MESSAGE` | string  | i18n    | Override default `api.maintenance.message`. Same value goes to all locales when set.            |

If `MAINTENANCE_MODE_UNTIL` is malformed or unset, `Retry-After` defaults to
**60 seconds** and `until` / `until_unix` are `null`. A warning is logged once
per request on invalid input — fix the env var or remove it.

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
# → 200 + {"maintenance":true,...}
curl -i https://staging.himrate.com/api/v1/channels/123
# → 503 + Retry-After + JSON
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
    MAINTENANCE_MODE_UNTIL: "2026-05-12T20:30:00Z"
```

Commit, deploy via the normal pipeline (`git push origin main` → CI runs
`kamal deploy -d staging`), revert the commit + redeploy to flip off.

Option A is preferable for unplanned maintenance — it doesn't require a CI
round-trip. Option B is preferable for planned maintenance because it leaves
an audit trail in git.

### Choosing `MAINTENANCE_MODE_UNTIL`

- Set to **the end of the expected window + a small buffer** (e.g. 5 min).
- Use UTC ISO 8601 with the trailing `Z` — `2026-05-12T20:30:00Z`.
- The frontend uses `until_unix` to render a countdown ("back in 4 min").
- If the actual maintenance overruns: bump the env var and `kamal app boot`
  again. Clients pick up the new `Retry-After` on their next poll (max
  60 seconds lag if no `UNTIL` was set).

### Choosing the message

- Russian default (no override): `"Системные работы. Возвращаемся скоро."`
- English default (no override): `"Scheduled maintenance. Back shortly."`
- Locale is detected per-request from `Accept-Language` header or `?lang=`
  query param. Default = `I18n.default_locale` (`:en`).
- For incident-specific messaging, set `MAINTENANCE_MODE_MESSAGE` — this
  overrides the i18n default for **all** locales. Example:
  ```
  MAINTENANCE_MODE_MESSAGE="Migrating database. ETA 5 min. status.himrate.com"
  ```

## Smoke checklist (after flipping)

```bash
# 1. /up still healthy (load balancer / Kamal proxy)
curl -i https://staging.himrate.com/up
# → 200

# 2. Polling endpoint reports maintenance: true
curl -i https://staging.himrate.com/api/v1/health/maintenance
# → 200 + {"maintenance":true,"message":"...","retry_after_seconds":60,...}

# 3. Real API endpoint is blocked
curl -i https://staging.himrate.com/api/v1/channels/123 -H "Authorization: Bearer xxx"
# → 503 + Retry-After: 60 + JSON

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
