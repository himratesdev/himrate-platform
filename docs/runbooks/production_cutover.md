# Production cutover (когда появится отдельная production-destination)

> Контекст: PO-решение 2026-09-01 — «прод = staging». Единственная Kamal-destination
> `staging` на домашнем сервере обслуживает himrate.com / app.himrate.com / api.himrate.com
> (RAILS_ENV=staging, Cloudflare Tunnel, proxy ssl:false). Отдельной production-destination
> НЕТ; первый production-деплой = Launch. Этот runbook — чеклист на тот момент.

## Чеклист cutover

1. **Хост**: `config/deploy.production.yml` → живой хост (сейчас указывает на мёртвый
   HOSTKEY 82.21.7.48) + `config/accessory_hosts.yml` production-секция.
2. **Секреты**: ротация `KAMAL_REGISTRY_PASSWORD` (PAT истёк; staging живёт на
   GITHUB_TOKEN — production-путь требует PAT), Google OAuth secret (TASK-082),
   полный прогон «Validate required secrets» из accessory-ops.yml для production env.
3. **Flipper**: перенести нужные флаги из `STAGING_ALL_FLAGS` в `ALL_FLAGS` (или снять
   env-guard) — на проде иначе молчат sигналы #8/#9/#12, chatter-профили,
   follower-снапшоты, edges, ЛК (`saas_lk_live`). `billing_auto_subscription_creation`
   НЕ переносить (staging/dev-only by design).
4. **Калибровка**: засеять production windowed ρ*-ячейки (gate0-seed / rho-reseed) ДО
   включения `ti_v2_cowindowed_rho` — windowed-вердикт на cumulative-ячейках даст
   конвенционный mismatch по всему флоту.
5. **База**: `himrate_production` + pg_partman партиции + ClickHouse schema
   (`rake clickhouse:setup`) + RedisBloom-модуль в production redis.
6. **DV**: полный `prompts/deployment_verification.md` (0a–0e + 1–19) + STRICT
   live-verify на живом RU-стримере до объявления «прод жив».
7. Тег `v*.*.*` → job `deploy-production` (ни разу не запускался — первый прогон
   считать испытанием самого pipeline, не рутиной).
