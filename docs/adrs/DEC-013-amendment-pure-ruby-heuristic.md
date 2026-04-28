# ADR DEC-13 Amendment — Pure Ruby Heuristic Replaces sklearn (BUG-010 PR3)

**Status:** Active
**Original ADR:** DEC-13 (Notion: BUG-010 v3.0 Architecture Decisions)
**Amendment Date:** 2026-04-28
**Amendment Author:** Dev Agent (BUG-010 PR3)
**Authoritative Notion link:** Operator updates BUG-010 ADR v1.0 § DEC-13 with link к this file.

## Original DEC-13 (summary)

> Drift forecast model: Python sklearn shell exec (Open3.capture2e к
> `scripts/ml_ops/train_drift_forecast.py` + `predict_drift_forecast.py`).
> Rationale: Ruby ML libraries (rumale) less mature than sklearn для logistic
> regression baseline, time series forecasting, feature engineering.

## Amendment

Drift forecast model: **pure Ruby heuristic baseline** (mean + stddev интервалов между
consecutive drift events per (destination, accessory) pair). Trainer computes baseline
weekly, persists в `drift_baselines` table. Inference reads + predicts next drift =
`last_detected_at + mean_interval` с ±1σ bounds, confidence по sample_count.

Python invocation removed entirely.

## Rationale (why amendment)

1. **Statistical insignificance pre-launch.** Drift events accumulate ~50-200/year при
   8 accessories × 2 destinations. sklearn LogisticRegression на ≤200 samples × ~10
   features = overfit risk + не статистически значимо. Heuristic estimator (mean+stddev
   interval per pair) делает то же самое статистически чище — interpretable, testable,
   no black box.

2. **Boundary cost vs benefit.** Python invocation requires:
   - python3 + sklearn в production Docker image (~200MB extra)
   - JSON serialization в both directions для каждого inference run
   - pickle artifact storage management
   - Process spawn overhead per invocation
   Cost не оправдан для baseline accuracy которая Ruby heuristic уже даёт.

3. **Build for years principle (per CLAUDE.md).** Heuristic implementation is honest
   engineering при текущем data scale. Premature ML = premature optimization.

## Revisit Trigger

When `accessory_drift_events` count ≥ **10K** (статистически robust для true ML models)
AND specific value documented (e.g., per-pair survival analysis с covariates что Ruby
heuristic не может capture). At that point: re-evaluate sklearn integration с full
training pipeline + pickle artifact + scheduled retraining.

Estimated trigger date: depends на drift detection cadence + accessory count growth —
likely 12-24 months post-launch если current cadence holds.

## Code references

- `app/models/drift_baseline.rb` — DriftBaseline AR model (5+ samples → sufficient_data?)
- `app/services/ml_ops/drift_forecast_trainer_service.rb` — pure Ruby compute
- `app/services/ml_ops/drift_forecast_inference_service.rb` — predict + ±1σ bounds
- `db/migrate/20260428100001_create_drift_baselines.rb` — schema

## Migration cost

Zero ongoing — Python scripts (`scripts/ml_ops/*.py`) never deployed (PR2 left как dormant
skeleton, PR3 removed entirely). DB schema additions: 1 new table (drift_baselines),
1 column extension к drift_forecast_predictions (PR3 commit для M-3 fix).
