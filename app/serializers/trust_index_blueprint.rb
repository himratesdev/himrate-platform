# frozen_string_literal: true

# TASK-031: TrustIndexHistory serializer with tier-scoped views.

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

    field :label do |tih, _options|
      erv = tih&.erv_percent&.to_f
      return nil unless erv

      if erv >= 80
        I18n.t("erv.labels.green", default: "Аномалий не замечено")
      elsif erv >= 50
        I18n.t("erv.labels.yellow", default: "Аномалия онлайна")
      else
        I18n.t("erv.labels.red", default: "Значительная аномалия онлайна")
      end
    end

    field :label_color do |tih, _options|
      erv = tih&.erv_percent&.to_f
      return nil unless erv

      if erv >= 80 then "green"
      elsif erv >= 50 then "yellow"
      else "red"
      end
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
