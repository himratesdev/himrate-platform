# frozen_string_literal: true

# TASK-038 FR-026: 30-day trend delta + direction.
# Returns { delta_30d: Float, direction: "up"|"down"|"flat" } or { delta_30d: nil, direction: nil }.

module Hs
  class TrendCalculator
    DIRECTION_THRESHOLD = 2.0 # pts

    def call(channel)
      current = HealthScore
        .where(channel_id: channel.id)
        .order(calculated_at: :desc)
        .pick(:health_score)

      historical = HealthScore
        .where(channel_id: channel.id)
        .where("calculated_at <= ?", 30.days.ago)
        .order(calculated_at: :desc)
        .pick(:health_score)

      return { delta_30d: nil, direction: nil } unless current && historical

      delta = (current.to_f - historical.to_f).round(2)
      direction = classify_direction(delta)

      { delta_30d: delta, direction: direction }
    end

    private

    def classify_direction(delta)
      return "up" if delta > DIRECTION_THRESHOLD
      return "down" if delta < -DIRECTION_THRESHOLD

      "flat"
    end
  end
end
