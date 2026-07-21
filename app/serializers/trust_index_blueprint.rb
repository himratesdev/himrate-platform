# frozen_string_literal: true

# TASK-031: TrustIndexHistory serializer with tier-scoped views.
# PR3b (T1-074): per-ROW engine discrimination — a v2 row emits the v2 contract fields
# (erv/erv_interval/authenticity/band + band-derived label), a v1 row emits the legacy set;
# the other engine's fields are nil. One blueprint serves mixed lists across the cutover.

class TrustIndexBlueprint < Blueprinter::Base
  # === Headline (Guest) ===
  view :headline do
    field :engine_version do |tih, _options|
      tih&.engine_version
    end

    field :ti_score do |tih, _options|
      tih&.trust_index_score&.to_f
    end

    field :classification do |tih, _options|
      tih&.classification
    end

    field :erv_percent do |tih, _options|
      tih&.erv_percent&.to_f
    end

    # v2: the subtracted real-viewer COUNT + interval + authenticity + band (nil on v1 rows)
    field :erv do |tih, _options|
      tih&.erv
    end

    field :erv_interval do |tih, _options|
      next nil unless tih&.engine_version == "v2"

      { lo: tih.erv_lo, hi: tih.erv_hi }
    end

    field :authenticity do |tih, _options|
      tih&.authenticity&.to_f
    end

    field :band do |tih, _options|
      next nil unless tih&.engine_version == "v2" && tih.band_row

      { row: tih.band_row, color: tih.band_color,
        label_key: TrustIndex::V2::BandClassifier.label_key_for(tih.band_row), sub: tih.band_sub }
    end

    field :confirmed_anomaly do |tih, _options|
      next nil unless tih&.engine_version == "v2"

      { shown: tih.confirmed_anomaly }
    end

    # erv_count from denormalized ccv (v1 derivation; v2 rows: erv IS the count — emit it here too
    # so legacy readers of erv_count keep a meaningful value across the cutover)
    field :erv_count do |tih, _options|
      next tih.erv if tih&.engine_version == "v2"

      erv = tih&.erv_percent&.to_f
      ccv = tih&.ccv.to_i
      next nil unless erv && ccv.positive?

      (ccv * erv / 100.0).round
    end

    # Labels: v2 → band label_key via I18n (5 colors incl. amber/grey); v1 → ErvCalculator
    field :label do |tih, _options|
      if tih&.engine_version == "v2"
        next nil unless tih.band_row

        next I18n.t(TrustIndex::V2::BandClassifier.label_key_for(tih.band_row), default: nil)
      end
      erv = tih&.erv_percent&.to_f
      next nil unless erv

      label_data = TrustIndex::ErvCalculator.resolve_label(erv)
      I18n.locale == :ru ? label_data[:ru] : label_data[:en]
    end

    field :label_color do |tih, _options|
      next tih.band_color if tih&.engine_version == "v2"

      erv = tih&.erv_percent&.to_f
      next nil unless erv

      TrustIndex::ErvCalculator.resolve_label(erv)[:color]
    end

    field :cold_start_status do |tih, _options|
      tih&.cold_start_status
    end

    field :cold_start_tier do |tih, _options|
      tih&.cold_start_tier
    end

    field :confidence do |tih, _options|
      tih&.confidence&.to_f
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
