# frozen_string_literal: true

# BUG-010 PR2 (FR-099/100, ADR DEC-13): ML inference (dormant pre-launch).
# Daily cron. Loads latest model artifact (skip if none). Generates predictions per
# (destination, accessory) для next 30 days, INSERTs high-confidence (>=0.6) к DB.

require "open3"
require "json"

module MlOps
  class DriftForecastInferenceService
    PYTHON_INFERENCE = Rails.root.join("scripts/ml_ops/predict_drift_forecast.py")
    MODEL_DIR = Rails.root.join("var/ml_models")
    HORIZON_DAYS = 30
    MIN_CONFIDENCE = 0.6

    Result = Struct.new(:status, :predictions_count, :model_version, keyword_init: true)

    def self.call
      latest = latest_model
      unless latest
        Rails.logger.info("MlOps::DriftForecastInferenceService: no_model — skip inference")
        return Result.new(status: :no_model)
      end

      pairs = AccessoryHostsConfig.destinations.flat_map do |destination|
        accessories_for(destination).map { |accessory| { destination: destination, accessory: accessory } }
      end

      predictions = pairs.flat_map do |pair|
        run_inference(model_path: latest[:path], **pair).map do |raw|
          raw.merge(destination: pair[:destination], accessory: pair[:accessory], model_version: latest[:version])
        end
      end

      filtered = predictions.select { |p| p[:confidence].to_f >= MIN_CONFIDENCE }
      filtered.each { |p| persist!(p) }

      Result.new(status: :predicted, predictions_count: filtered.size, model_version: latest[:version])
    end

    def self.latest_model
      Dir.glob(File.join(MODEL_DIR, "drift_forecast_v*.bin")).map do |f|
        version_match = File.basename(f).match(/drift_forecast_(v\d+)\.bin/)
        next unless version_match
        { path: f, version: version_match[1] }
      end.compact.max_by { |m| File.mtime(m[:path]) }
    end

    def self.accessories_for(_destination)
      %w[db redis grafana prometheus loki alertmanager prometheus-pushgateway promtail]
    end

    def self.run_inference(model_path:, destination:, accessory:)
      stdin_data = JSON.generate(destination: destination, accessory: accessory, horizon_days: HORIZON_DAYS)
      command = ["python3", PYTHON_INFERENCE.to_s, "--model", model_path]
      output, status = Open3.capture2e(*command, stdin_data: stdin_data)
      return [] unless status.exitstatus.zero?

      JSON.parse(output, symbolize_names: true).fetch(:predictions, [])
    rescue StandardError => e
      Rails.logger.warn("MlOps::DriftForecastInferenceService: inference failed — #{e.class}: #{e.message}")
      []
    end

    def self.persist!(prediction)
      DriftForecastPrediction.create!(
        destination: prediction[:destination],
        accessory: prediction[:accessory],
        predicted_drift_at: Time.parse(prediction[:predicted_drift_at]),
        confidence: prediction[:confidence],
        model_version: prediction[:model_version],
        generated_at: Time.current
      )
    end

    private_class_method :latest_model, :accessories_for, :run_inference, :persist!
  end
end
