# frozen_string_literal: true

# TASK-031: TrustIndexHistory serializer with tier-scoped views.
# V1-RETIRE (2026-09-02): v2-only — rows are always engine_version='v2'; the legacy
# ti_score/classification/erv_percent/cold_start_status/confidence fields and the
# ErvCalculator label path are gone (retired scalars, columns dropped).

class TrustIndexBlueprint < Blueprinter::Base
  # === Headline (Guest) ===
  view :headline do
    field :engine_version do |tih, _options|
      tih&.engine_version
    end

    # The subtracted real-viewer COUNT + interval + authenticity + band
    field :erv do |tih, _options|
      tih&.erv
    end

    field :erv_interval do |tih, _options|
      next nil unless tih

      { lo: tih.erv_lo, hi: tih.erv_hi }
    end

    field :authenticity do |tih, _options|
      tih&.authenticity&.to_f
    end

    # tooltip = the server-resolved scale hint (request locale), paired with tooltip_key the same
    # way `label` below is paired with label_key — otherwise the key is all a web client ever gets.
    field :band do |tih, _options|
      next nil unless tih&.band_row

      tooltip_key = TrustIndex::V2::BandClassifier.tooltip_key_for(tih.band_row)
      { row: tih.band_row, color: tih.band_color,
        label_key: TrustIndex::V2::BandClassifier.label_key_for(tih.band_row),
        tooltip_key: tooltip_key, tooltip: I18n.t(tooltip_key, default: nil),
        sub: tih.band_sub }
    end

    field :confirmed_anomaly do |tih, _options|
      next nil unless tih

      { shown: tih.confirmed_anomaly }
    end

    # erv IS the count — legacy wire key kept for erv_count readers.
    field :erv_count do |tih, _options|
      tih&.erv
    end

    field :label do |tih, _options|
      next nil unless tih&.band_row

      I18n.t(TrustIndex::V2::BandClassifier.label_key_for(tih.band_row), default: nil)
    end

    field :label_color do |tih, _options|
      tih&.band_color
    end

    field :cold_start_tier do |tih, _options|
      tih&.cold_start_tier
    end

    field :confidence_marker do |tih, _options|
      tih&.confidence_marker
    end

    field :calculated_at do |tih, _options|
      tih&.calculated_at&.iso8601
    end
  end

  # === Drill-down (Free) — headline + signal_breakdown ===
  view :drill_down do
    include_view :headline

    field :signal_breakdown do |tih, _options|
      tih&.signal_breakdown || {}
    end
  end

  # === Full (Premium) — drill-down ===
  view :full do
    include_view :drill_down
  end
end
