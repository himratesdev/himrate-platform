# frozen_string_literal: true

# TASK-038 FR-027 / BR-28: Top X% badge text generation on backend.
# Returns localized string like "Top 28% in Just Chatting" / "Топ-28% в Just Chatting".

module Hs
  class BadgeTextFormatter
    def self.call(percentile:, category_key:, locale: I18n.locale)
      return nil unless percentile

      top_percent = (100 - percentile).round
      display_name = resolve_display_name(category_key)

      I18n.t(
        "hs.badge.top_x_in_category",
        locale: locale,
        top_percent: top_percent,
        category: display_name,
        default: "Top #{top_percent}% in #{display_name}"
      )
    end

    def self.resolve_display_name(key)
      HealthScoreCategory.find_by(key: key)&.display_name || key.to_s.humanize
    end
  end
end
