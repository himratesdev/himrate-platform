# frozen_string_literal: true

# TASK-039 FR-034: Cross-module narrative orchestrator.
# Collects signals from TrendCalculator + AnomalyFrequencyScorer, assigns priority
# (P0/P1/P2), returns top-N insights with i18n-interpolated messages + action deep-links.
#
# Priority assignment (ADR §4.6):
#   - P0: critical degradation (TI drop ≥ p0_ti_delta_min_pts, OR anomalies elevated
#         ≥ elevated_threshold_pct)
#   - P1: notable changes (anomaly frequency elevated но <p0)
#   - P2: positive improvements (trend rising)
#
# Output: max N insights (configurable, default 3), sorted по priority DESC + recency.

module Trends
  module Analysis
    class MovementInsights
      ACTION_VIEW_COMPONENTS = "view_components"
      ACTION_VIEW_ANOMALY = "view_anomaly"

      def self.call(channel:, from:, to:, trend:, anomaly_frequency:, top_improvement: nil, top_degradation: nil)
        new(
          channel: channel,
          from: from,
          to: to,
          trend: trend,
          anomaly_frequency: anomaly_frequency,
          top_improvement: top_improvement,
          top_degradation: top_degradation
        ).call
      end

      def initialize(channel:, from:, to:, trend:, anomaly_frequency:, top_improvement:, top_degradation:)
        @channel = channel
        @from = from
        @to = to
        @trend = trend || {}
        @anomaly_frequency = anomaly_frequency || {}
        @top_improvement = top_improvement
        @top_degradation = top_degradation
      end

      def call
        # SRS §10 alert trends.movement_insights.duration_p95 > 500ms.
        # Subscribers (StatsD/Prometheus) attach за кадром.
        start_monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        cfg = load_config
        candidates = []

        candidates << ti_drop_insight(cfg) if ti_dropped?(cfg)
        candidates << anomaly_spike_insight(cfg) if anomaly_elevated?(cfg)
        candidates << improvement_insight if @trend[:direction] == "rising" && @top_improvement

        ranked = candidates.compact.sort_by { |i| [ priority_weight(i[:priority]), -(i[:recency_score] || 0) ] }
        insights = ranked.first(cfg[:top_n])
        result = insights.empty? ? [ flat_insight ] : insights

        duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_monotonic) * 1000).round(2)
        # CR N-4: input signals summary в payload — для debug p95>500ms outliers
        # operator видит reconstructed state без повторного query.
        ActiveSupport::Notifications.instrument(
          "trends.movement_insights.completed",
          channel_id: @channel&.id,
          insights_count: result.size,
          top_priority: result.first&.dig(:priority),
          duration_ms: duration_ms,
          input_signals: {
            trend_direction: @trend[:direction],
            trend_delta: @trend[:delta],
            anomaly_verdict: @anomaly_frequency[:verdict],
            anomaly_delta_percent: @anomaly_frequency[:delta_percent]
          }
        )

        result
      end

      private

      def load_config
        {
          top_n: SignalConfiguration.value_for("trends", "insights", "top_n_count").to_i,
          p0_ti_delta: SignalConfiguration.value_for("trends", "insights", "p0_ti_delta_min_pts").to_f,
          elevated_pct: SignalConfiguration.value_for("trends", "anomaly_freq", "elevated_threshold_pct").to_f
        }
      end

      def ti_dropped?(cfg)
        delta = @trend[:delta]
        return false if delta.nil?

        @trend[:direction] == "declining" && delta.abs >= cfg[:p0_ti_delta]
      end

      def anomaly_elevated?(cfg)
        @anomaly_frequency[:verdict] == "elevated" && (@anomaly_frequency[:delta_percent] || 0) >= cfg[:elevated_pct]
      end

      def ti_drop_insight(_cfg)
        # CR M-2: per-locale humanize чтобы избежать locale-leak.
        # Было: один top_name вычислялся через I18n.t без locale (использовал I18n.locale)
        # и попадал и в message_ru, и в message_en → русскому юзеру показывался английский
        # текст в message_en и наоборот.
        name = @top_degradation&.dig(:name)
        top_ru = name ? humanize(name, :ru) : I18n.t("trends.insights.components_fallback", locale: :ru, default: "компоненты")
        top_en = name ? humanize(name, :en) : I18n.t("trends.insights.components_fallback", locale: :en, default: "components")
        abs_delta = @trend[:delta].to_f.abs.round(1)

        {
          priority: "P0",
          icon: "🔴",
          message_ru: I18n.t("trends.insights.message.ti_drop", locale: :ru, delta: abs_delta, top_degradation: top_ru),
          message_en: I18n.t("trends.insights.message.ti_drop", locale: :en, delta: abs_delta, top_degradation: top_en),
          action: ACTION_VIEW_COMPONENTS,
          recency_score: 100
        }
      end

      def anomaly_spike_insight(_cfg)
        delta = @anomaly_frequency[:delta_percent].to_f.round(0)
        {
          priority: "P1",
          icon: "🟡",
          message_ru: I18n.t("trends.insights.message.anomaly_spike", locale: :ru, delta: delta),
          message_en: I18n.t("trends.insights.message.anomaly_spike", locale: :en, delta: delta),
          action: ACTION_VIEW_ANOMALY,
          recency_score: 80
        }
      end

      def improvement_insight
        # Metric label itself локализован (v2.2 future — сейчас консистентен с ExplanationBuilder default).
        metric_ru = I18n.t("trends.insights.metric.trust_index", locale: :ru, default: "Trust Index")
        metric_en = I18n.t("trends.insights.metric.trust_index", locale: :en, default: "Trust Index")
        top_ru = humanize(@top_improvement[:name], :ru)
        top_en = humanize(@top_improvement[:name], :en)
        delta = @trend[:delta].to_f.round(1)

        {
          priority: "P2",
          icon: "🟢",
          message_ru: I18n.t("trends.insights.message.improvement", locale: :ru,
            metric: metric_ru, delta: delta, top_improvement: top_ru),
          message_en: I18n.t("trends.insights.message.improvement", locale: :en,
            metric: metric_en, delta: delta, top_improvement: top_en),
          action: ACTION_VIEW_COMPONENTS,
          recency_score: 50
        }
      end

      def flat_insight
        {
          priority: "P3",
          icon: "⚪",
          message_ru: I18n.t("trends.insights.message.flat", locale: :ru),
          message_en: I18n.t("trends.insights.message.flat", locale: :en),
          action: nil,
          recency_score: 0
        }
      end

      def priority_weight(priority)
        { "P0" => 0, "P1" => 1, "P2" => 2, "P3" => 3 }.fetch(priority, 99)
      end

      # CR M-2: accepts locale → per-locale i18n lookup. Fallback = humanized
      # identifier (English-ish) when no signals.* translation exists.
      def humanize(name, locale)
        I18n.t("signals.#{name}", locale: locale, default: name.to_s.humanize)
      end
    end
  end
end
