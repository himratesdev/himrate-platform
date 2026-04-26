# ML Drift Forecasting Runbook

## Цель

ML-based drift forecasting per accessory. Pre-launch **dormant** (no training, no predictions) до accumulation >=50 events. Post-launch когда data sufficient → weekly model training, daily inference, predictions overlay в Drift Trend dashboard.

## Architecture

- **Trainer:** `MlOps::DriftForecastTrainerService` — weekly cron `0 3 * * 0` (Sundays 3am UTC), queue `:long_running`
- **Inference:** `MlOps::DriftForecastInferenceService` — daily cron `0 4 * * *` (4am UTC), queue `:default`
- **ML library:** Python sklearn via `Open3.capture3` shell exec (per ADR DEC-13 — Ruby ML libraries immature)
- **Model storage:** filesystem `var/ml_models/drift_forecast_v<N>.bin`
- **Predictions table:** `drift_forecast_predictions` (id, destination, accessory, predicted_drift_at, confidence, model_version, generated_at)

## Pre-launch dormant phase

```ruby
class MlOps::DriftForecastTrainerService
  MIN_EVENTS = 50
  WINDOW_DAYS = 90
  
  def self.call
    events = AccessoryDriftEvent.where(detected_at: WINDOW_DAYS.days.ago..)
    return log_skip_insufficient_data(events.count) if events.count < MIN_EVENTS
    # ... rest of training
  end
end
```

Pre-launch behavior:
- Trainer runs weekly cron BUT skips if <50 events (logs "insufficient data, skip count=N")
- Inference runs daily cron BUT skips if no model artifact exists
- Drift Trend dashboard forecast overlay panel renders empty (no data)
- Cost Attribution + Cost dashboards: same dormant pattern (per `grafana_dashboards.md` Cost section)

## Activation criteria

Triggered automatically когда:
- Worker accumulates >=50 drift events за last 90 days (`accessory_drift_events` count)
- Realistic timeline: ~3-6 months post-launch при typical drift cadence

After activation:
- Weekly trainer runs → trains model on historical data → saves artifact `var/ml_models/drift_forecast_v<N>.bin`
- Daily inference runs → loads latest artifact → generates predictions per (destination, accessory) для next 30 days → INSERT drift_forecast_predictions
- Drift Trend dashboard auto-displays forecast overlay panel

## ML pipeline details

### Feature engineering (per ADR DEC-17)

Baseline features:
- `drift_count_per_week` (rolling)
- `mean_resolution_time_seconds` (per accessory historical)
- `accessory_one_hot` (db, redis, grafana, prometheus, loki, alertmanager, promtail, prometheus-pushgateway)
- `destination_one_hot` (staging, production)
- `day_of_week_one_hot`
- `hour_of_day` (0-23)
- `recent_rollback_count_30d` (0-N)

Future iterations: cross-accessory correlation (drift на db correlates с redis?), seasonality (deploy windows), trend.

### Model

Baseline: logistic regression OR random forest (sklearn). Output: probability of drift in next 30 days per (destination, accessory).

### Training process

1. Fetch events from `accessory_drift_events` last 90 days
2. Feature engineer
3. Split train/test 80/20
4. Train sklearn model
5. Compute accuracy on test set
6. IF accuracy <70% (per ADR DEC-17 / Edge#37) → log warning, save model anyway (best available)
7. Save artifact с version bump
8. Update Prometheus metric `ml_model_accuracy_percent`

### Inference process

1. Load latest model artifact
2. Generate features per (destination, accessory) для next 30 days
3. Predict drift probability per day
4. INSERT high-confidence predictions (>=0.6) в drift_forecast_predictions
5. Older predictions cleaned via cron (>60 days old DELETE)

## Manual operations

### Force training

```bash
docker exec -it himrate-job bundle exec rails runner "MlOps::DriftForecastTrainerService.call"
```

### Force inference

```bash
docker exec -it himrate-job bundle exec rails runner "MlOps::DriftForecastInferenceService.call"
```

### Check model accuracy

```ruby
# Rails console
DriftForecastPrediction.where(generated_at: 30.days.ago..).count
# vs actual drift events
AccessoryDriftEvent.where(detected_at: 30.days.ago..).count
# Manual accuracy check
```

OR Grafana dashboard panel `ml_model_accuracy_percent` metric.

### Inspect model artifact

```bash
ls -lh var/ml_models/
# drift_forecast_v1.bin   2.3K
# drift_forecast_v2.bin   2.5K
```

## Edge cases

### Model artifact corrupted

Inference service catches load error, logs, returns no predictions. Next training cycle creates new artifact.

### Prediction divergence от reality

Track `ml_model_accuracy_percent`. IF <70% → trigger immediate retrain (via cron exception OR manual). Refine features (per ADR DEC-17 future iterations).

### Insufficient features (mostly null)

Common pre-launch — trainer skips. Post-launch: features compute fine.

## Validation

Pre-merge: training service runs против synthetic test data:

```ruby
# In spec
let!(:fake_events) do
  60.times do |i|
    create(:accessory_drift_event, detected_at: i.days.ago, ...)
  end
end

it "trains model when events sufficient" do
  expect(File).to exist("var/ml_models/drift_forecast_v1.bin")
end
```

## Future enhancements

- Cross-accessory correlation features
- Seasonality detection
- Forecasting horizon expansion (90 days vs 30)
- Model ensemble (logistic + random forest + gradient boosting)
- AutoML hyperparameter tuning

## Related

- `accessory_drift_detection.md` — detection (data source)
- `grafana_dashboards.md` — Drift Trend forecast overlay
- ADR DEC-13, DEC-17 — ML decisions
