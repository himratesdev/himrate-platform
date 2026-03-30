# frozen_string_literal: true

# TASK-031: TrustIndexHistory serializer with tier-scoped views.
# Label logic delegated to ErvCalculator (single source of truth).

class TrustIndexBlueprint < Blueprinter::Base
  # === Headline (Guest) ===
  view :headline do
    field :ti_score do |tih, _options|
      tih&.trust_index_score&.to_f
    end

    field :classification do |tih, _options|
      tih&.classification
    end

    field :erv_percent do |tih, _options|
      tih&.erv_percent&.to_f
    end

    # erv_count computed from erv_percent × stream CCV (peak_ccv or avg_ccv — no extra query)
    field :erv_count do |tih, _options|
      erv = tih&.erv_percent&.to_f
      next nil unless erv && tih&.stream

      ccv = tih.stream.peak_ccv.to_i
      ccv = tih.stream.avg_ccv.to_i if ccv.zero?
      next nil if ccv.zero?

      (ccv * erv / 100.0).round
    end

    # Labels from ErvCalculator (single source of truth, not duplicated)
    field :label do |tih, _options|
      erv = tih&.erv_percent&.to_f
      next nil unless erv

      label_data = TrustIndex::ErvCalculator.resolve_label(erv)
      I18n.locale == :ru ? label_data[:ru] : label_data[:en]
    end

    field :label_color do |tih, _options|
      erv = tih&.erv_percent&.to_f
      next nil unless erv

      TrustIndex::ErvCalculator.resolve_label(erv)[:color]
    end

    field :cold_start_status do |tih, _options|
      tih&.cold_start_status
    end

    field :confidence do |tih, _options|
      tih&.confidence&.to_f
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

  # === Full (Premium) — drill-down + rehabilitation ===
  view :full do
    include_view :drill_down

    field :rehabilitation_penalty do |tih, _options|
      tih&.rehabilitation_penalty&.to_f
    end

    field :rehabilitation_bonus do |tih, _options|
      tih&.rehabilitation_bonus&.to_f
    end
  end
end
