# frozen_string_literal: true

# TASK-029 FR-003/009: ERV Calculator.
# ERV = CCV × (TI / 100). Labels per CLAUDE.md v3 (legally safe).
# Confidence intervals: >=0.7 point, 0.3-0.6 range ±15%, <0.3 insufficient.

module TrustIndex
  class ErvCalculator
    LABELS = {
      green: { range: 80..100, ru: "Аномалий не замечено", en: "No anomalies detected", color: "green" },
      yellow: { range: 50..79, ru: "Аномалия онлайна", en: "Audience anomaly detected", color: "yellow" },
      red: { range: 0..49, ru: "Значительная аномалия онлайна", en: "Significant audience anomaly", color: "red" }
    }.freeze

    # Returns Hash with erv_count, erv_percent, label, label_color, confidence_display, range
    def self.compute(ti_score:, ccv:, confidence:)
      return { erv_count: nil, erv_percent: nil, label: nil, label_color: nil, confidence_display: "unavailable" } unless ccv&.positive?

      erv_percent = ti_score.to_f.clamp(0.0, 100.0)
      erv_count = (ccv * erv_percent / 100.0).round

      label_data = resolve_label(erv_percent)

      confidence_display = if confidence >= 0.7
                             { type: "point", display: "~#{erv_count}" }
      elsif confidence >= 0.3
                             low = (erv_count * 0.85).round
                             high = (erv_count * 1.15).round
                             { type: "range", display: "#{low}–#{high}", low: low, high: high }
      else
                             { type: "insufficient", display: "Insufficient data" }
      end

      {
        erv_count: erv_count,
        erv_percent: erv_percent.round(2),
        label: label_data[:ru],
        label_en: label_data[:en],
        label_color: label_data[:color],
        confidence_display: confidence_display
      }
    end

    def self.resolve_label(erv_percent)
      rounded = erv_percent.round(0)
      LABELS.each_value do |data|
        return data if data[:range].include?(rounded)
      end
      LABELS[:red]
    end

    # Made public for TrustIndexBlueprint (single source of truth for label logic)
  end
end
