# frozen_string_literal: true

# TASK-039 FR-034: Cross-module narrative orchestrator.
# Collects signals from TrendCalculator + AnomalyFrequencyScorer + TierChangeCounter
# + RehabilitationTracker (TASK-038), assigns priority (P0/P1/P2), returns top-N
# insights with i18n-interpolated messages + action deep-links.
#
# Priority assignment (ADR §4.6):
#   - P0: critical degradation (TI drop ≥ p0_ti_delta_min_pts, OR rehab active OR
#         anomalies elevated ≥ elevated_threshold_pct)
#   - P1: notable changes (recent tier_change OR anomaly frequency elevated но <p0)
#   - P2: positive improvements (trend rising OR rehab progressing)
#
# Output: max N insights (configurable, default 3), sorted по priority DESC + recency.

module Trends
  module Analysis
    class MovementInsights
      ACTION_VIEW_COMPONENTS = "view_components"
      ACTION_VIEW_ANOMALY = "view_anomaly"
      ACTION_VIEW_REHABILITATION = "view_rehabilitation"
      ACTION_VIEW_TIER_CHANGE = "view_tier_change"

      def self.call(channel:, from:, to:, trend:, anomaly_frequency:, tier_changes:, rehabilitation: nil, top_improvement: nil, top_degradation: nil)
        new(
          channel: channel,
          from: from,
          to: to,
          trend: trend,
          anomaly_frequency: anomaly_frequency,
          tier_changes: tier_changes,
          rehabilitation: rehabilitation,
          top_improvement: top_improvement,
          top_degradation: top_degradation
        ).call
      end

      def initialize(channel:, from:, to:, trend:, anomaly_frequency:, tier_changes:, rehabilitation:, top_improvement:, top_degradation:)
        @channel = channel
        @from = from
        @to = to
        @trend = trend || {}
        @anomaly_frequency = anomaly_frequency || {}
        @tier_changes = tier_changes || {}
        @rehabilitation = rehabilitation || {}
        @top_improvement = top_improvement
        @top_degradation = top_degradation
      end

      def call
        cfg = load_config
        candidates = []

        candidates << ti_drop_insight(cfg) if ti_dropped?(cfg)
        candidates << rehabilitation_insight if rehabilitation_active?
        candidates << anomaly_spike_insight(cfg) if anomaly_elevated?(cfg)
        candidates << tier_change_insight(cfg) if recent_tier_change?(cfg)
        candidates << improvement_insight if @trend[:direction] == "rising" && @top_improvement

        ranked = candidates.compact.sort_by { |i| [ priority_weight(i[:priority]), -(i[:recency_score] || 0) ] }
        insights = ranked.first(cfg[:top_n])

        insights.empty? ? [ flat_insight ] : insights
      end

      private

      def load_config
        {
          top_n: SignalConfiguration.value_for("trends", "insights", "top_n_count").to_i,
          p0_ti_delta: SignalConfiguration.value_for("trends", "insights", "p0_ti_delta_min_pts").to_f,
          p1_tier_recency: SignalConfiguration.value_for("trends", "insights", "p1_tier_change_recency_days").to_i,
          elevated_pct: SignalConfiguration.value_for("trends", "anomaly_freq", "elevated_threshold_pct").to_f
        }
      end

      def ti_dropped?(cfg)
        delta = @trend[:delta]
        return false if delta.nil?

        @trend[:direction] == "declining" && delta.abs >= cfg[:p0_ti_delta]
      end

      def rehabilitation_active?
        @rehabilitation[:rehabilitation_active] == true
      end

      def anomaly_elevated?(cfg)
        @anomaly_frequency[:verdict] == "elevated" && (@anomaly_frequency[:delta_percent] || 0) >= cfg[:elevated_pct]
      end

      def recent_tier_change?(cfg)
        latest = @tier_changes[:latest]
        return false if latest.nil?

        latest[:occurred_at] && latest[:occurred_at] >= cfg[:p1_tier_recency].days.ago
      end

      def ti_drop_insight(_cfg)
        top_name = @top_degradation ? humanize(@top_degradation[:name]) : "components"
        {
          priority: "P0",
          icon: "🔴",
          message_ru: I18n.t("trends.insights.message.ti_drop", locale: :ru, delta: @trend[:delta].to_f.abs.round(1), top_degradation: top_name),
          message_en: I18n.t("trends.insights.message.ti_drop", locale: :en, delta: @trend[:delta].to_f.abs.round(1), top_degradation: top_name),
          action: ACTION_VIEW_COMPONENTS,
          recency_score: 100
        }
      end

      def rehabilitation_insight
        progress = @rehabilitation[:progress] || {}
        bonus = @rehabilitation[:bonus] || {}
        {
          priority: "P0",
          icon: "🟠",
          message_ru: I18n.t("trends.insights.message.rehabilitation_progress", locale: :ru,
            clean: progress[:clean_streams_completed] || 0,
            required: progress[:clean_streams_required] || 15,
            bonus: bonus[:bonus_pts_earned] || 0),
          message_en: I18n.t("trends.insights.message.rehabilitation_progress", locale: :en,
            clean: progress[:clean_streams_completed] || 0,
            required: progress[:clean_streams_required] || 15,
            bonus: bonus[:bonus_pts_earned] || 0),
          action: ACTION_VIEW_REHABILITATION,
          recency_score: 90
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

      def tier_change_insight(_cfg)
        latest = @tier_changes[:latest]
        {
          priority: "P1",
          icon: "🟡",
          message_ru: I18n.t("trends.insights.message.tier_change", locale: :ru,
            from: latest[:from_tier] || "—", to: latest[:to_tier], date: latest[:occurred_at]&.to_date),
          message_en: I18n.t("trends.insights.message.tier_change", locale: :en,
            from: latest[:from_tier] || "—", to: latest[:to_tier], date: latest[:occurred_at]&.to_date),
          action: ACTION_VIEW_TIER_CHANGE,
          recency_score: days_ago_score(latest[:occurred_at])
        }
      end

      def improvement_insight
        metric = "Trust Index"
        top_name = humanize(@top_improvement[:name])
        {
          priority: "P2",
          icon: "🟢",
          message_ru: I18n.t("trends.insights.message.improvement", locale: :ru,
            metric: metric, delta: @trend[:delta].to_f.round(1), top_improvement: top_name),
          message_en: I18n.t("trends.insights.message.improvement", locale: :en,
            metric: metric, delta: @trend[:delta].to_f.round(1), top_improvement: top_name),
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

      def days_ago_score(ts)
        return 0 if ts.nil?

        days = (Time.current - ts) / 1.day
        [ 100 - days.to_i, 0 ].max
      end

      def humanize(name)
        I18n.t("signals.#{name}", default: name.to_s.humanize)
      end
    end
  end
end
