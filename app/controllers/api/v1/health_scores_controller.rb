# frozen_string_literal: true

# TASK-032 + TASK-038 FR-024: Health Score endpoint — enriched payload.
# All classification/label logic via Hs::Classifier (single source of truth).
# Added: components_percentile, warnings, rehabilitation, data_freshness, latest_tier_change,
#        badge_text, category, category_weights, recommendations.

module Api
  module V1
    class HealthScoresController < Api::BaseController
      include Channelable

      before_action :authenticate_user!
      before_action :set_channel

      def show
        authorize @channel, :view_health_score?

        payload = Rails.cache.fetch(cache_key, expires_in: 1.hour) do
          build_payload
        end

        render json: { data: payload }
      end

      private

      def cache_key
        latest = HealthScore.where(channel_id: @channel.id).order(calculated_at: :desc).first
        cat = latest&.category
        weights_version = weights_version_for(cat)
        "health_score:cat_v#{weights_version}:#{@channel.id}"
      end

      def weights_version_for(category_key)
        return 0 unless category_key

        SignalConfiguration
          .where(signal_type: "health_score", category: category_key)
          .maximum(:updated_at)&.to_i || 0
      end

      def build_payload
        latest_hs = HealthScore.where(channel_id: @channel.id).order(calculated_at: :desc).first
        stream_count = @channel.streams.where.not(ended_at: nil).count
        cold_start_tier = cold_start_tier_for(stream_count)
        freshness = Hs::DataFreshnessChecker.call(latest_hs&.calculated_at)

        # Hide HS if very_stale (EC-06)
        return empty_payload(stream_count, cold_start_tier) if freshness == "very_stale"
        return empty_payload(stream_count, cold_start_tier) unless latest_hs

        score = latest_hs.health_score&.to_f
        tier = Hs::Classifier.for(score)
        components = build_components(latest_hs)
        category_key = latest_hs.category
        weights = load_category_weights(category_key) if category_key
        component_percentiles = Hs::ComponentPercentileService.new(@channel).call(category_key) if category_key
        overall_percentile = Reputation::PercentileService.new(channel: @channel).call if stream_count >= 30
        trend = Hs::TrendCalculator.new.call(@channel)
        recommendations = build_recommendations(latest_hs)
        badge_text = Hs::BadgeTextFormatter.call(
          percentile: overall_percentile,
          category_key: category_key,
          locale: I18n.locale
        )
        latest_tier_change = build_latest_tier_change(freshness)
        rehabilitation = TrustIndex::RehabilitationTracker.call(@channel)

        payload = {
          health_score: score,
          label: tier ? I18n.t(tier[:i18n_key], default: tier[:key].humanize) : nil,
          label_color: tier&.dig(:color),
          label_bg_hex: tier&.dig(:bg_hex),
          label_text_hex: tier&.dig(:text_hex),
          badge_text: badge_text,
          confidence_badge: latest_hs.confidence_level || cold_start_tier,
          stream_count: stream_count,
          cold_start_tier: cold_start_tier,
          category: category_key,
          category_weights: weights,
          components: components,
          components_percentile: component_percentiles,
          warnings: components_warnings(components),
          percentile: overall_percentile,
          trend_delta_30d: trend[:delta_30d],
          trend_direction: trend[:direction],
          latest_tier_change: latest_tier_change,
          rehabilitation: rehabilitation,
          data_freshness: freshness,
          recommendations: recommendations,
          calculated_at: latest_hs.calculated_at.iso8601
        }

        payload.merge(trends(policy))
      end

      def build_components(hs_record)
        {
          ti: hs_record.ti_component&.to_f,
          stability: hs_record.stability_component&.to_f,
          engagement: hs_record.engagement_component&.to_f,
          growth: hs_record.growth_component&.to_f,
          consistency: hs_record.consistency_component&.to_f
        }
      end

      def components_warnings(components)
        components.transform_values { |v| v.nil? ? nil : v < 50 }
      end

      def load_category_weights(category_key)
        Hs::WeightsLoader.new.call(category_key)
      rescue Hs::WeightsLoader::MissingWeights
        nil
      end

      def build_recommendations(hs_record)
        return [] unless policy.can_receive_recommendations?
        return [] unless Flipper.enabled?(:hs_recommendations, current_user)

        Hs::RecommendationService.new.call(
          channel: @channel,
          user: current_user,
          health_score_record: hs_record
        )
      end

      def build_latest_tier_change(freshness)
        return nil if freshness == "very_stale"

        event = HsTierChangeEvent.tier_changes
          .for_channel(@channel.id)
          .within_days(7)
          .order(occurred_at: :desc)
          .first
        return nil unless event

        {
          from: event.from_tier,
          to: event.to_tier,
          hs_before: event.hs_before&.to_f,
          hs_after: event.hs_after&.to_f,
          occurred_at: event.occurred_at.iso8601
        }
      end

      def empty_payload(stream_count, cold_start_tier)
        {
          health_score: nil,
          label: nil,
          label_color: nil,
          confidence_badge: cold_start_tier,
          stream_count: stream_count,
          cold_start_tier: cold_start_tier,
          data_freshness: "very_stale",
          components: {},
          recommendations: []
        }
      end

      def trends(channel_policy)
        if channel_policy.effective_business_access?
          {
            trend_30d: hs_trend(30),
            trend_60d: hs_trend(60),
            trend_90d: hs_trend(90),
            trend_365d: hs_trend(365)
          }
        elsif channel_policy.premium_access?
          { trend_30d: hs_trend(30) }
        else
          {}
        end
      end

      def hs_trend(days)
        HealthScore.where(channel: @channel)
                   .where("calculated_at >= ?", days.days.ago)
                   .order(calculated_at: :asc)
                   .pluck(:calculated_at, :health_score)
                   .map { |at, hs| { date: at.to_date.iso8601, health_score: hs.to_f } }
      end

      def cold_start_tier_for(stream_count)
        case stream_count
        when 0..2 then "insufficient"
        when 3..6 then "provisional_low"
        when 7..9 then "provisional"
        when 10..29 then "full"
        else "deep"
        end
      end

      def policy
        @policy ||= ChannelPolicy.new(current_user, @channel)
      end
    end
  end
end
