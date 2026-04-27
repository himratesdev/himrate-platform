# frozen_string_literal: true

# BUG-010 PR3 (FR-095..103, ADR DEC-13 corrigendum): Ruby heuristic baseline trainer.
# Replaces sklearn Python invocation (rejected — overkill для нашего scale + adds Python
# в production image). Per (destination, accessory) pair: computes mean + stddev интервалов
# между consecutive drift events. Inference uses к predict next drift = last_drift_at +
# mean_interval ± stddev.
#
# Weekly cron via MlOps::DriftForecastTrainerWorker. Skips pair если <MIN_SAMPLES events accumulated.
# Persists DriftBaseline row (UPSERT по unique (destination, accessory)).

module MlOps
  class DriftForecastTrainerService
    WINDOW_DAYS = 90
    MIN_SAMPLES = DriftBaseline::MIN_SAMPLES

    Result = Struct.new(:status, :pairs_trained, :pairs_skipped, keyword_init: true)

    def self.call
      pairs_trained = 0
      pairs_skipped = 0

      group_drift_events.each do |pair, intervals|
        if intervals.size < MIN_SAMPLES - 1 # N events → N-1 intervals
          pairs_skipped += 1
          next
        end

        baseline = compute_baseline(intervals)
        upsert_baseline(pair: pair, baseline: baseline, sample_count: intervals.size + 1)
        pairs_trained += 1
      end

      Rails.logger.info(
        "MlOps::DriftForecastTrainerService: trained=#{pairs_trained} skipped=#{pairs_skipped} " \
        "algorithm=#{DriftBaseline::ALGORITHM_VERSION}"
      )
      Result.new(status: :ok, pairs_trained: pairs_trained, pairs_skipped: pairs_skipped)
    end

    # Group resolved + open drift events per (destination, accessory). Computes intervals
    # (seconds between consecutive detected_at values, sorted). Open events контрибутируют
    # последнюю detected_at но не closing interval — standard survival analysis pattern.
    def self.group_drift_events
      events = AccessoryDriftEvent
        .where(detected_at: WINDOW_DAYS.days.ago..)
        .order(:destination, :accessory, :detected_at)
        .pluck(:destination, :accessory, :detected_at)

      grouped = events.group_by { |destination, accessory, _at| [ destination, accessory ] }

      grouped.transform_values do |triples|
        timestamps = triples.map { |_d, _a, at| at }
        timestamps.each_cons(2).map { |earlier, later| (later - earlier).to_i }
      end
    end

    def self.compute_baseline(intervals)
      mean = intervals.sum.to_f / intervals.size
      variance = intervals.sum { |i| (i - mean)**2 } / intervals.size
      stddev = Math.sqrt(variance)
      { mean: mean.round, stddev: stddev.round }
    end

    def self.upsert_baseline(pair:, baseline:, sample_count:)
      destination, accessory = pair
      record = DriftBaseline.find_or_initialize_by(destination: destination, accessory: accessory)
      record.update!(
        mean_interval_seconds: baseline[:mean],
        stddev_interval_seconds: baseline[:stddev],
        sample_count: sample_count,
        algorithm_version: DriftBaseline::ALGORITHM_VERSION,
        computed_at: Time.current
      )
    end

    private_class_method :group_drift_events, :compute_baseline, :upsert_baseline
  end
end
