# frozen_string_literal: true

# BUG-010 PR2 (FR-095..103, ADR DEC-13/17): ML drift forecast trainer (dormant pre-launch).
# Weekly cron. Skips если <50 events accumulated в last 90 days.
# Python sklearn shell exec per ADR DEC-13 — Ruby ML libraries immature.
#
# Pre-launch: log skip + return. Production-ready skeleton, activates когда data sufficient.

require "open3"
require "json"

module MlOps
  class DriftForecastTrainerService
    MIN_EVENTS = 50
    WINDOW_DAYS = 90
    MODEL_DIR = Rails.root.join("var/ml_models")
    PYTHON_TRAINER = Rails.root.join("scripts/ml_ops/train_drift_forecast.py")

    Result = Struct.new(:status, :events_count, :model_version, :accuracy, keyword_init: true)

    def self.call
      events_count = AccessoryDriftEvent.where(detected_at: WINDOW_DAYS.days.ago..).count

      if events_count < MIN_EVENTS
        Rails.logger.info(
          "MlOps::DriftForecastTrainerService: insufficient_data events=#{events_count} required=#{MIN_EVENTS}"
        )
        return Result.new(status: :insufficient_data, events_count: events_count)
      end

      payload = build_training_dataset(events_count)
      version_number = next_model_version
      version_label = format("v%d", version_number)
      output, exit_status = run_python_trainer(payload: payload, version_number: version_number)

      if exit_status.zero?
        accuracy = parse_accuracy(output)
        Rails.logger.info(
          "MlOps::DriftForecastTrainerService: trained version=#{version_label} events=#{events_count} accuracy=#{accuracy}"
        )
        Result.new(status: :trained, events_count: events_count, model_version: version_label, accuracy: accuracy)
      else
        Rails.logger.error("MlOps::DriftForecastTrainerService: training failed — #{output}")
        Result.new(status: :failed, events_count: events_count)
      end
    end

    def self.build_training_dataset(_count)
      # Feature engineering per ADR DEC-17: drift_count_per_week, mean_resolution_time,
      # accessory_one_hot, destination_one_hot, day_of_week, hour_of_day, recent_rollback_count_30d.
      events = AccessoryDriftEvent.where(detected_at: WINDOW_DAYS.days.ago..).find_each.to_a
      events.map do |e|
        {
          destination: e.destination,
          accessory: e.accessory,
          detected_at: e.detected_at.iso8601,
          resolved_at: e.resolved_at&.iso8601,
          mttr_seconds: e.mttr_seconds
        }
      end
    end

    def self.next_model_version
      FileUtils.mkdir_p(MODEL_DIR)
      existing = Dir.glob(File.join(MODEL_DIR, "drift_forecast_v*.bin")).map do |f|
        File.basename(f).match(/drift_forecast_v(\d+)\.bin/)&.captures&.first.to_i
      end
      Integer(existing.max || 0) + 1
    end

    def self.run_python_trainer(payload:, version_number:)
      stdin_data = JSON.generate(payload)
      # Integer coercion + format("%d") — defense-in-depth против command injection
      # (next_model_version returns Integer, но enforce здесь explicitly для Brakeman static analysis).
      filename = format("drift_forecast_v%d.bin", Integer(version_number))
      output_path = MODEL_DIR.join(filename)
      command = [ "python3", PYTHON_TRAINER.to_s, "--output", output_path.to_s ]
      output, status = Open3.capture2e(*command, stdin_data: stdin_data)
      [ output, status.exitstatus ]
    rescue Errno::ENOENT
      [ "python3 OR trainer script missing — see scripts/ml_ops/train_drift_forecast.py", 1 ]
    end

    def self.parse_accuracy(output)
      output.scan(/accuracy[:=]\s*([\d.]+)/i).flatten.last&.to_f
    end

    private_class_method :build_training_dataset, :next_model_version, :run_python_trainer, :parse_accuracy
  end
end
