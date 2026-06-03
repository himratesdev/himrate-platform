# frozen_string_literal: true

# TASK-029 FR-003/009: ERV Calculator.
# ERV = CCV × (TI / 100). Labels per CLAUDE.md v3 (legally safe) with a Phase 4
# J PR-D top-tier upgrade (2026-06-03).
#
# Pre-PR-D the green tier (80-100) carried one label: «Аномалий не замечено» /
# «No anomalies detected». Per PO directive 2026-06-02 «для clean signals
# TI=100 + label "Аудитория реальная"», the very top band (90-100,
# high-confidence clean) now displays «Аудитория реальная» / «Audience is real»
# — a positive affirmation rather than a neutral "no anomalies" phrasing.
# Honest big streamers (Recrent, blueMark partners) deserve the strongest
# signal; mid-green (80-89) keeps the neutral phrasing because confidence is
# good but not unequivocal. Both bands stay green-colored — the colour mapping
# doesn't break any extension client that filters on `label_color` alone.
#
# Legal safety preserved: «Аудитория реальная» is a positive affirmation about
# the audience signal, not a negative claim about bots/scraping/fake accounts.
# Matches the v3 doctrine in CLAUDE.md (no "боты"/"накрутка"/"фейк" terms;
# only neutral or positive phrasing).
#
# Confidence intervals: >=0.7 point, 0.3-0.6 range ±15%, <0.3 insufficient.

module TrustIndex
  class ErvCalculator
    # Phase 4 J PR-D: 4-tier labels (was 3-tier pre-PR). Tiers are disjoint and
    # exhaustive over [0..100]; resolve_label returns on first match so the order
    # below is hash-iteration order but correctness doesn't depend on it.
    LABELS = {
      excellent: { range: 90..100, ru: "Аудитория реальная", en: "Audience is real", color: "green" },
      green: { range: 80..89, ru: "Аномалий не замечено", en: "No anomalies detected", color: "green" },
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
