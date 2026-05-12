# CleanupWorker — Retention / Backfill Runbook

**Контекст:** TASK-086 / ADR-086. `CleanupWorker` (`app/workers/cleanup_worker.rb`) — единственный owner retention для time-series таблиц (`trust_index_histories`, `ti_signals`, `ccv_snapshots`, `chatters_snapshots`, `chat_messages`). Запускается nightly через `sidekiq-cron` (`config/initializers/sidekiq_cron.rb`), Flipper-guarded флагом `:cleanup_worker`. Удаляет старые строки батчами (`BATCH_SIZE = 1000`, каждый батч — отдельная транзакция с `SET LOCAL statement_timeout='30s'`).

Этот документ — операционные процедуры: первый production deploy, ручной backfill, отчёты, аварийный stop.

---

## 1. Оператор-обзор

| Что | Где |
| --- | --- |
| Worker | `app/workers/cleanup_worker.rb` (`perform`: Flipper guard → advisory lock → sub-runs → row-stats → auto-disable check → heartbeat) |
| Flipper флаг | `:cleanup_worker` — в `FlipperDefaults::ALL_FLAGS` ⇒ **enabled-by-default на каждом boot** |
| Cron | nightly (`config/initializers/sidekiq_cron.rb`) |
| Retention config | таблица `signal_configurations` (rows seeded миграцией `20260512100001_seed_cleanup_retention_thresholds.rb`); `SignalConfiguration` — source of truth, `DEFAULT_RETENTION_DAYS = 90` — last-resort fallback |
| TIH floor | `CleanupWorker::MIN_RETENTION_DAYS = 7` — `retention_days` для `trust_index_histories` клампится снизу до 7д (защита от misconfigured admin-row `retention_days = 0`) |
| TIH conservation (FR-002/003) | rank-1 (финальная) TIH на каждый stream и **все** TIH live-стримов (`streams.ended_at IS NULL`) **никогда** не удаляются |
| Audit | таблица `cleanup_audit_logs` (retention indefinite — никогда не auto-удаляется); по строке на sub-run (`success` / `partial` / `error` / `skipped`) |
| Auto-disable | 3 подряд `error`-строки для таблицы ⇒ `Cleanup::AutoDisableService` выключает `:cleanup_worker` + critical Alertmanager alert |
| Метрики | Prometheus push-gateway gauges `cleanup_worker_*` (см. `prometheus/rules/cleanup_health.yml`), Grafana dashboard `grafana/dashboards/cleanup_health.json` |
| Rake | `lib/tasks/cleanup.rake` — `cleanup:initial_backfill[table,dry_run]`, `cleanup:report[start,end,format]`, `cleanup:restore_from_archive[...]` (pending) |

Valid `table` для rake-задач: `tih | ti_signals | ccv_snapshots | chatters_snapshots | chat_messages` (это ключи `TABLE_MAP`, **не** реальные имена таблиц — `tih` ↦ `trust_index_histories`).

---

## 2. Первый production deploy (ОБЯЗАТЕЛЬНО прочитать перед launch)

`:cleanup_worker` входит в `FlipperDefaults::ALL_FLAGS`, поэтому на первом же production boot он будет **включён**, и первый nightly cron-запуск против непустой production-БД попытается удалить **всю** накопленную историю старше retention одним прогоном (батчами, но без верхней границы по объёму). Чтобы первый scheduled run не был гигантским неконтролируемым DELETE:

1. **Бэкап БД.** Сделать backup production-БД (стандартное pre-deploy ожидание перед любой data-mutating миграцией/деплоем). Это база на случай ошибки конфигурации retention.

2. **Dry-run preview** (безопасно, ничего не удаляет — `dry_run` по умолчанию `true`):

   ```bash
   bin/rails cleanup:initial_backfill[tih]
   bin/rails cleanup:initial_backfill[ti_signals]
   bin/rails cleanup:initial_backfill[ccv_snapshots]
   bin/rails cleanup:initial_backfill[chatters_snapshots]
   bin/rails cleanup:initial_backfill[chat_messages]
   ```

   Печатает eligible-count + sample. Сверить, что числа адекватны (не «вся таблица» из-за `retention_days = 0`).

3. **Backfill для реального удаления** — выполнить с `dry_run = false` для каждой релевантной таблицы **до того, как сработает первый nightly cron**:

   ```bash
   bin/rails cleanup:initial_backfill[tih,false]
   bin/rails cleanup:initial_backfill[ti_signals,false]
   bin/rails cleanup:initial_backfill[ccv_snapshots,false]
   bin/rails cleanup:initial_backfill[chatters_snapshots,false]
   bin/rails cleanup:initial_backfill[chat_messages,false]
   ```

   `cleanup:initial_backfill` — chunked + throttled + `statement_timeout` на каждый chunk; безопасно прогонять на проде, можно перезапускать (идемпотентно). После этого таблицы уже в пределах retention, и первый nightly запуск `CleanupWorker` будет инкрементальным (день к дню), а не «всё за один раз».

   > Если по какой-то причине backfill не успели прогнать до первого cron — это не катастрофа (TIH conservation защищает финальные/live строки, остальные DELETE-ы батчевые с timeout-ом), но прогон будет тяжёлым по I/O. Можно временно `Flipper.disable(:cleanup_worker)`, прогнать backfill, затем `Flipper.enable(:cleanup_worker)`.

4. (Опционально) убедиться, что retention-конфиг засеян: `SignalConfiguration.where(signal_type: ['trust_index_histories','cleanup'], param_name: 'retention_days').pluck(:category, :param_value)` — должны быть значения из `20260512100001_seed_cleanup_retention_thresholds.rb`.

---

## 3. Ручной backfill / повторный прогон

То же `cleanup:initial_backfill[table,dry_run]`:

```bash
bin/rails cleanup:initial_backfill[tih]          # dry-run preview (default)
bin/rails cleanup:initial_backfill[tih,false]    # реальное удаление
```

Cutoff берётся из `SignalConfiguration` (для `tih` — с тем же клампом снизу до `MIN_RETENTION_DAYS`, что и в worker'е). Безопасно перезапускать.

---

## 4. Отчёт по cleanup_audit_logs

```bash
bin/rails cleanup:report                          # all time, text
bin/rails cleanup:report[2026-04-01,2026-05-01]   # за апрель, text
bin/rails cleanup:report[,,json]                  # all time, json
bin/rails cleanup:report[2026-05-01,,csv]         # с 1 мая, csv
```

Агрегирует по таблицам: runs, total deleted, разбивка статусов, failure-rate, avg/peak `duration_ms`.

---

## 5. Аварийный stop / re-enable

```ruby
Flipper.disable(:cleanup_worker)   # следующий perform запишет skipped-audit-row и ничего не удалит
Flipper.enable(:cleanup_worker)    # обратно
```

Auto-disable (`Cleanup::AutoDisableService`) сам выключит флаг после 3 подряд `error`-строк для одной таблицы (+ critical alert). После фикса причины — `Flipper.enable(:cleanup_worker)` вручную.

---

## 6. Связанные файлы

- `app/workers/cleanup_worker.rb` — worker
- `app/services/cleanup/` — `BackfillRunner`, `AutoDisableService`, `ErrorSerializer`, `PartialRunError`
- `lib/tasks/cleanup.rake` — operator rake-задачи
- `app/models/cleanup_audit_log.rb`, `app/models/latest_tih_per_stream.rb` (MV)
- `prometheus/rules/cleanup_health.yml`, `grafana/dashboards/cleanup_health.json`
- `docs/adrs/` — ADR-086 (решения по архитектуре retention)
