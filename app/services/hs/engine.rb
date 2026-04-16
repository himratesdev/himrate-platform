# frozen_string_literal: true

# TASK-038 FR-001: HS Engine — pure computation orchestrator.
# Worker delegates to Engine. Engine returns result hash, worker persists.
# Per-category weights from DB. Provisional formula for 1-6 streams.
# Normalize weights on nil components.

module Hs
  class Engine
    PERIOD = 30.days

    def initialize(components: nil, weights_loader: nil)
      @components = components
      @weights_loader = weights_loader || WeightsLoader.new
    end

    # Returns hash:
    # {
    #   health_score: Float,
    #   components: { ti:, stability:, engagement:, growth:, consistency: },
    #   classification: String,
    #   confidence_level: String,
    #   category: String,
    #   category_weights: Hash,
    #   latest_stream: Stream,
    #   stream_count: Integer,
    #   applied_formula: :provisional | :full
    # }
    # OR { health_score: nil, ... } if insufficient data.
    def call(channel)
      completed = channel.streams.where.not(ended_at: nil)
      stream_count = completed.count
      return empty_result(channel) if stream_count.zero?

      latest_stream = completed.order(ended_at: :desc).first
      category_key = CategoryMapper.map(latest_stream&.game_name)
      weights = @weights_loader.call(category_key)

      comp_service = @components || Components.new(channel)
      components = comp_service.compute(stream_count: stream_count)

      applied_formula, health_score = compute_score(components, weights, stream_count)
      classification = Classifier.classification(health_score)

      {
        health_score: health_score&.round(2),
        components: components,
        classification: classification,
        confidence_level: assess_confidence(stream_count),
        category: category_key,
        category_weights: weights,
        latest_stream: latest_stream,
        stream_count: stream_count,
        applied_formula: applied_formula
      }
    end

    private

    # FR-007: 1-6 streams → provisional, 7+ → full
    def compute_score(components, weights, stream_count)
      if stream_count <= 6
        [ :provisional, provisional_hs(components) ]
      else
        [ :full, weighted_average(components, weights) ]
      end
    end

    # FR-007: HS = (0.30×TI + 0.20×Eng) / 0.50 × 100 — normalized to 0-100
    # TI/Eng are already in 0-100. Result: weighted average of available components.
    def provisional_hs(components)
      ti = components[:ti]
      eng = components[:engagement]

      total_weight = 0.0
      total_value = 0.0

      if ti
        total_weight += 0.30
        total_value += 0.30 * ti
      end

      if eng
        total_weight += 0.20
        total_value += 0.20 * eng
      end

      return nil if total_weight.zero?

      (total_value / total_weight).clamp(0.0, 100.0)
    end

    # FR-008: nil components excluded from numerator and denominator
    def weighted_average(components, weights)
      total_weight = 0.0
      total_value = 0.0

      weights.each do |key, weight|
        value = components[key]
        next if value.nil?

        total_weight += weight
        total_value += value * weight
      end

      return nil if total_weight.zero?

      (total_value / total_weight).clamp(0.0, 100.0)
    end

    def assess_confidence(stream_count)
      case stream_count
      when 0..2 then "insufficient"
      when 3..6 then "provisional_low"
      when 7..9 then "provisional"
      when 10..29 then "full"
      else "deep"
      end
    end

    def empty_result(_channel)
      {
        health_score: nil,
        components: {},
        classification: nil,
        confidence_level: "insufficient",
        category: nil,
        category_weights: nil,
        latest_stream: nil,
        stream_count: 0,
        applied_formula: nil
      }
    end
  end
end
