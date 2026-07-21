# frozen_string_literal: true

# TASK-039 FR-025: Generates RU/EN narrative for trend direction using
# improvement_signals + degradation_signals (Top-3 each, sorted by |delta|).
#
# Input:
#   - trend: {direction, delta, ...}  — from TrendCalculator
#   - improvement_signals: [{name, delta}, ...] — sorted DESC (positive delta)
#   - degradation_signals: [{name, delta}, ...] — sorted ASC (negative delta)
#   - metric_key: i18n KEY of the metric name (e.g. "trends.metric.trust_index"), resolved
#     per-locale INSIDE the builder. T1-074 surface-audit: callers used to pass ONE string
#     resolved under the request locale — it then leaked into BOTH explanation_ru and
#     explanation_en (RU narrative with an English metric name and vice versa).
#
# i18n keys: trends.explanation.*  (5 templates per locale).
# Graceful fallback: когда signals empty → generic "trends.explanation.rising_generic" etc.

module Trends
  module Analysis
    class ExplanationBuilder
      TOP_N_SIGNALS = 3

      def self.call(trend:, improvement_signals: [], degradation_signals: [], metric_key: "trends.metric.trust_index")
        new(
          trend: trend,
          improvement_signals: improvement_signals,
          degradation_signals: degradation_signals,
          metric_key: metric_key
        ).call
      end

      def initialize(trend:, improvement_signals:, degradation_signals:, metric_key:)
        @trend = trend || {}
        @improvement_signals = Array(improvement_signals).first(TOP_N_SIGNALS)
        @degradation_signals = Array(degradation_signals).first(TOP_N_SIGNALS)
        @metric_key = metric_key
      end

      def call
        direction = @trend[:direction]
        delta = format_delta(@trend[:delta])

        key_base = select_template_key(direction)

        {
          explanation_ru: I18n.t("trends.explanation.#{key_base}", locale: :ru, metric: metric_for(:ru), delta: delta, top_signals: signal_list(:ru, key_base)),
          explanation_en: I18n.t("trends.explanation.#{key_base}", locale: :en, metric: metric_for(:en), delta: delta, top_signals: signal_list(:en, key_base)),
          improvement_signals: @improvement_signals,
          degradation_signals: @degradation_signals
        }
      end

      private

      def metric_for(locale)
        I18n.t(@metric_key, locale: locale)
      end

      def select_template_key(direction)
        case direction
        when "rising"
          @improvement_signals.any? ? "rising_with_improvements" : "rising_generic"
        when "declining"
          @degradation_signals.any? ? "declining_with_degradations" : "declining_generic"
        else
          "flat"
        end
      end

      def signal_list(locale, key_base)
        signals =
          if key_base.include?("improvements")
            @improvement_signals
          elsif key_base.include?("degradations")
            @degradation_signals
          else
            []
          end

        # CR N-2: separator одинаковый для обоих locale — упростили тернарник.
        signals
          .map { |s| "#{localize_signal_name(s[:name], locale)} (#{format_signed(s[:delta])})" }
          .join(", ")
      end

      def localize_signal_name(name, locale)
        # Signals имеют собственные i18n keys в других namespaces (signals.*, hs.components.*).
        # Here we gracefully fallback to humanized string if no specific key.
        translated = I18n.t("signals.#{name}", locale: locale, default: nil)
        return translated if translated

        name.to_s.humanize
      end

      def format_delta(delta)
        return "—" if delta.nil?

        sign = delta.positive? ? "+" : ""
        "#{sign}#{delta.round(1)}"
      end

      def format_signed(delta)
        return "—" if delta.nil?

        sign = delta.positive? ? "+" : ""
        "#{sign}#{delta.round(1)}"
      end
    end
  end
end
