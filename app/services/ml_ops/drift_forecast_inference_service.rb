# frozen_string_literal: true

# BUG-010 PR3 (FR-099/100, ADR DEC-13 corrigendum): heuristic inference (pure Ruby).
# Daily cron via MlOps::DriftForecastInferenceWorker. For each pair с sufficient baseline:
# predicts next drift = last_detected_at + mean_interval. Confidence based на sample_count.
# Persists DriftForecastPrediction row если confidence >= MIN_CONFIDENCE.

module MlOps
  class DriftForecastInferenceService
    HORIZON_DAYS = 30
    MIN_CONFIDENCE = 0.6

    Result = Struct.new(:status, :predictions_count, :pairs_skipped, keyword_init: true)

    def self.call
      predictions_count = 0
      pairs_skipped = 0

      DriftBaseline.find_each do |baseline|
        unless baseline.sufficient_data?
          pairs_skipped += 1
          next
        end

        prediction = build_prediction(baseline)
        unless within_horizon?(prediction[:predicted_drift_at])
          pairs_skipped += 1
          next
        end
        if prediction[:confidence] < MIN_CONFIDENCE
          pairs_skipped += 1
          next
        end

        persist!(baseline: baseline, prediction: prediction)
        predictions_count += 1
      end

      Rails.logger.info(
        "MlOps::DriftForecastInferenceService: predictions=#{predictions_count} skipped=#{pairs_skipped}"
      )
      Result.new(status: :ok, predictions_count: predictions_count, pairs_skipped: pairs_skipped)
    end

    def self.build_prediction(baseline)
      last_detected_at = AccessoryDriftEvent
        .for_pair(baseline.destination, baseline.accessory)
        .maximum(:detected_at) || baseline.computed_at

      mean_interval = baseline.mean_interval_seconds
      stddev = baseline.stddev_interval_seconds.to_i
      predicted = last_detected_at + mean_interval.seconds
      # CR M-3: ±1σ confidence interval вокруг point estimate. Stddev может быть 0
      # для perfectly periodic events — interval collapses в point.
      lower_bound = last_detected_at + [ mean_interval - stddev, 1 ].max.seconds
      upper_bound = last_detected_at + (mean_interval + stddev).seconds
      confidence = compute_confidence(baseline.sample_count)
      {
        predicted_drift_at: predicted,
        predicted_at_lower_bound: lower_bound,
        predicted_at_upper_bound: upper_bound,
        confidence: confidence
      }
    end

    # Sample-size based confidence: 5..9 → 0.5; 10..29 → 0.7; 30+ → 0.85.
    # Statistical interpretation: больше observations = tighter prediction interval.
    def self.compute_confidence(sample_count)
      return 0.85 if sample_count >= 30
      return 0.70 if sample_count >= 10
      return 0.50 if sample_count >= 5

      0.0
    end

    def self.within_horizon?(predicted_at)
      predicted_at && predicted_at <= HORIZON_DAYS.days.from_now
    end

    def self.persist!(baseline:, prediction:)
      DriftForecastPrediction.create!(
        destination: baseline.destination,
        accessory: baseline.accessory,
        predicted_drift_at: prediction[:predicted_drift_at],
        predicted_at_lower_bound: prediction[:predicted_at_lower_bound],
        predicted_at_upper_bound: prediction[:predicted_at_upper_bound],
        confidence: prediction[:confidence],
        model_version: baseline.algorithm_version,
        generated_at: Time.current
      )
    end

    private_class_method :build_prediction, :compute_confidence, :within_horizon?, :persist!
  end
end
