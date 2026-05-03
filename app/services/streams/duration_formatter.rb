# frozen_string_literal: true

# TASK-085 FR-007 (BR-016): backend duration_text formatting per Accept-Language.
# Used by StreamSummaryBlueprint для Stream Summary endpoint response.
# i18n keys live in config/locales/api.{ru,en}.yml namespace stream_summary.duration_text.

module Streams
  class DurationFormatter
    SECONDS_PER_DAY = 86_400
    SECONDS_PER_HOUR = 3600

    # Returns formatted duration string per current I18n.locale.
    # Returns nil если seconds nil or zero/negative.
    def self.format(seconds:, locale: I18n.locale)
      return nil if seconds.nil? || seconds <= 0

      days = seconds / SECONDS_PER_DAY
      hours = (seconds % SECONDS_PER_DAY) / SECONDS_PER_HOUR
      minutes = (seconds % SECONDS_PER_HOUR) / 60

      if days.positive?
        I18n.t("stream_summary.duration_text.multi_day", D: days, H: hours, locale: locale)
      elsif hours.positive?
        I18n.t("stream_summary.duration_text.full", H: hours, M: minutes, locale: locale)
      else
        I18n.t("stream_summary.duration_text.short", M: minutes, locale: locale)
      end
    end
  end
end
