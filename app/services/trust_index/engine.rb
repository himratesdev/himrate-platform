# frozen_string_literal: true

# TASK-029 FR-001/002/005/006/010: Trust Index Engine.
# Aggregates 11 signal results → TI score (0-100) + classification.
# Weights from signal_configurations DB. Null signals skipped, weights renormalized.
# Bayesian shrinkage applied when confidence < 1.0.

module TrustIndex
  class Engine
    CLASSIFICATIONS = {
      "trusted" => 80..100,
      "needs_review" => 50..79,
      "suspicious" => 25..49,
      "fraudulent" => 0..24
    }.freeze

    Result = Data.define(:ti_score, :classification, :erv, :cold_start, :signal_breakdown,
                         :confidence, :rehabilitation_penalty, :rehabilitation_bonus)

    # Main entry point. Computes TI + ERV for a stream.
    # signal_results: Hash{signal_type => BaseSignal::Result} from Registry.compute_all
    # stream: ActiveRecord Stream
    # ccv: Integer (latest CCV)
    # category: String (stream category for config lookup)
    def compute(signal_results:, stream:, ccv:, category: "default")
      channel = stream.channel

      # FR-001/002: Weighted average of available signals
      ti_raw, breakdown, signal_confidence = compute_raw_ti(signal_results, category)

      # FR-004/005: Cold start + Bayesian shrinkage
      cold_start = ColdStartGuard.assess(channel)
      ti_bayesian = apply_bayesian(ti_raw, cold_start[:confidence])

      # FR-007: Rehabilitation
      rehab = RehabilitationCurve.apply(channel: channel, calculated_ti: ti_bayesian)
      ti_after_rehab = rehab[:adjusted_ti]

      # TASK-037 FR-007: Blend reputation (optional, 5% default weight)
      ti_final = apply_reputation(channel, ti_after_rehab, category).round(0).clamp(0, 100)

      # FR-006: Classification (from DB thresholds)
      classification = classify(ti_final)

      # FR-003/009: ERV
      erv = ErvCalculator.compute(ti_score: ti_final, ccv: ccv, confidence: cold_start[:confidence])

      # FR-010: Persist
      persist(
        stream: stream, channel: channel, ti_score: ti_final,
        classification: classification, cold_start: cold_start,
        erv: erv, breakdown: breakdown, confidence: signal_confidence,
        rehabilitation_penalty: rehab[:penalty], rehabilitation_bonus: rehab[:bonus],
        ccv: ccv
      )

      Result.new(
        ti_score: ti_final, classification: classification, erv: erv,
        cold_start: cold_start, signal_breakdown: breakdown,
        confidence: signal_confidence,
        rehabilitation_penalty: rehab[:penalty], rehabilitation_bonus: rehab[:bonus]
      )
    end

    private

    # TASK-037 FR-007: Blend reputation into TI (optional, weight configurable)
    def apply_reputation(channel, ti_score, category)
      rep = StreamerReputation.latest_for(channel.id)
      return ti_score unless rep&.calculated_at

      scores = [ rep.growth_pattern_score, rep.follower_quality_score, rep.engagement_consistency_score, rep.pattern_history_score ].compact
      return ti_score if scores.empty?

      rep_score = scores.sum / scores.size

      rep_weight = begin
        SignalConfiguration.value_for("reputation", category, "weight_in_ti").to_f
      rescue SignalConfiguration::ConfigurationMissing
        0.05
      end

      (1.0 - rep_weight) * ti_score + rep_weight * rep_score
    end

    def compute_raw_ti(signal_results, category)
      available = signal_results.select { |_, r| r.value && r.confidence > 0 }

      if available.empty?
        pop_mean = population_mean
        return [ pop_mean, {}, 0.0 ]
      end

      # Load weights, renormalize
      weights = {}
      available.each_key do |type|
        weights[type] = SignalConfiguration.value_for(type, category, "weight_in_ti").to_f
      rescue SignalConfiguration::ConfigurationMissing
        weights[type] = 1.0 / available.size
      end

      total_weight = weights.values.sum
      if total_weight.zero?
        pop_mean = population_mean
        return [ pop_mean, {}, 0.0 ]
      end

      # Log warning if weights don't sum to ~1.0 before normalization
      if available.size == 11 && (total_weight - 1.0).abs > 0.01
        Rails.logger.warn("TrustIndex::Engine: weights sum=#{total_weight.round(4)}, expected ~1.0")
      end

      # Weighted bot_score: higher signal value = more bots
      bot_score = 0.0
      breakdown = {}

      available.each do |type, result|
        normalized_weight = weights[type] / total_weight
        contribution = result.value * result.confidence * normalized_weight
        bot_score += contribution

        breakdown[type] = {
          value: result.value.round(4),
          confidence: result.confidence.round(2),
          weight: normalized_weight.round(4),
          contribution: contribution.round(4)
        }
      end

      ti_score = ((1.0 - bot_score) * 100).clamp(0, 100)
      avg_confidence = available.values.sum(&:confidence) / available.size

      [ ti_score, breakdown, avg_confidence.round(2) ]
    end

    def apply_bayesian(ti_raw, confidence)
      return population_mean if confidence.zero?

      confidence * ti_raw + (1.0 - confidence) * population_mean
    end

    def classify(ti_score)
      thresholds = load_classification_thresholds
      thresholds.each do |label, range|
        return label if range.include?(ti_score.round(0))
      end
      "fraudulent"
    end

    def load_classification_thresholds
      {
        "trusted" => (classification_threshold("trusted_min").to_i..100),
        "needs_review" => (classification_threshold("needs_review_min").to_i..classification_threshold("trusted_min").to_i - 1),
        "suspicious" => (classification_threshold("suspicious_min").to_i..classification_threshold("needs_review_min").to_i - 1),
        "fraudulent" => (0..classification_threshold("suspicious_min").to_i - 1)
      }
    rescue SignalConfiguration::ConfigurationMissing
      CLASSIFICATIONS
    end

    def classification_threshold(param)
      SignalConfiguration.value_for("trust_index", "default", param)
    end

    def population_mean
      SignalConfiguration.value_for("trust_index", "default", "population_mean").to_f
    rescue SignalConfiguration::ConfigurationMissing
      Rails.logger.error("TrustIndex::Engine: population_mean not in DB, using fallback 65")
      65.0
    end

    def persist(stream:, channel:, ti_score:, classification:, cold_start:, erv:,
                breakdown:, confidence:, rehabilitation_penalty:, rehabilitation_bonus:, ccv:)
      TrustIndexHistory.create!(
        channel: channel,
        stream: stream,
        trust_index_score: ti_score,
        confidence: confidence,
        signal_breakdown: breakdown,
        calculated_at: Time.current,
        classification: classification,
        cold_start_status: cold_start[:status],
        erv_percent: erv[:erv_percent],
        rehabilitation_penalty: rehabilitation_penalty,
        rehabilitation_bonus: rehabilitation_bonus,
        ccv: ccv
      )

      ErvEstimate.create!(
        stream: stream,
        timestamp: Time.current,
        erv_count: erv[:erv_count] || 0,
        erv_percent: erv[:erv_percent] || 0,
        confidence: confidence,
        label: erv[:label]
      )
    rescue ActiveRecord::RecordInvalid => e
      Rails.logger.error("TrustIndex::Engine: persist failed — #{e.message}")
      raise
    end
  end
end
