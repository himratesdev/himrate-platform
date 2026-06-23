# frozen_string_literal: true

# TASK-A1 Phase C1 (philosophy-v2): Trends API — nested under /api/v1/channels/:channel_id/trends/*.
# Actions per SRS v3.0: erv, trust_index, stability, anomalies, components, categories, weekday_patterns.
#
# Controller тонкий (ai-dev-team/CLAUDE.md convention): params → endpoint service → render.
# Cache via Rails.cache.fetch с versioned key + race_condition_ttl.
# Policy: authorize @channel, :view_trends_historical?.
# Errors: invalid_period / insufficient_data → 400; policy violations → 403 via ApplicationController rescue_from.

module Api
  module V1
    module Channels
      class TrendsController < Api::BaseController
        include Channelable

        before_action :authenticate_user!
        before_action :set_channel
        before_action :authorize_trends
        before_action :authorize_365d_if_requested

        rescue_from Trends::Api::BaseEndpointService::InvalidPeriod,
          Trends::Api::BaseEndpointService::InvalidGranularity,
          with: :render_invalid_params

        # GET /api/v1/channels/:channel_id/trends/erv
        def erv
          render_cached("erv") do
            Trends::Api::ErvEndpointService.new(
              channel: @channel, period: params[:period], granularity: params[:granularity],
              user: current_user
            ).call
          end
        end

        # GET /api/v1/channels/:channel_id/trends/trust_index
        def trust_index
          render_cached("trust_index") do
            Trends::Api::TrustIndexEndpointService.new(
              channel: @channel, period: params[:period], granularity: params[:granularity],
              user: current_user
            ).call
          end
        end

        # GET /api/v1/channels/:channel_id/trends/anomalies
        def anomalies
          render_cached("anomalies", extra_key: "p#{params[:page] || 1}_pp#{params[:per_page] || 50}") do
            Trends::Api::AnomaliesEndpointService.new(
              channel: @channel, period: params[:period],
              severity: params[:severity], attributed_only: params[:attributed_only],
              page: params[:page], per_page: params[:per_page],
              user: current_user
            ).call
          end
        end

        # GET /api/v1/channels/:channel_id/trends/components
        def components
          render_cached("components", extra_key: "g#{params[:group] || 'all'}") do
            Trends::Api::ComponentsEndpointService.new(
              channel: @channel, period: params[:period], group: params[:group],
              user: current_user
            ).call
          end
        end

        # GET /api/v1/channels/:channel_id/trends/stability (FR-003, M3)
        def stability
          render_cached("stability") do
            Trends::Api::StabilityEndpointService.new(
              channel: @channel, period: params[:period],
              user: current_user
            ).call
          end
        end

        # GET /api/v1/channels/:channel_id/trends/categories (FR-008, M13)
        def categories
          render_cached("categories") do
            Trends::Api::CategoriesEndpointService.new(
              channel: @channel, period: params[:period],
              user: current_user
            ).call
          end
        end

        # GET /api/v1/channels/:channel_id/trends/patterns/weekday (FR-009, M14)
        def weekday_patterns
          render_cached("weekday_patterns") do
            Trends::Api::WeekdayPatternsEndpointService.new(
              channel: @channel, period: params[:period],
              user: current_user
            ).call
          end
        end

        private

        def authorize_trends
          authorize @channel, :view_trends_historical?
        end

        # FR-013: 365d tier-gated — Business only.
        # CR M-2 + N-3: unified structured 403 через Pundit rescue_from (BaseController
        # resolve_error_code → "TRENDS_BUSINESS_REQUIRED" → structured error+CTA).
        def authorize_365d_if_requested
          return unless params[:period] == "365d"

          authorize @channel, :view_365d_trends?
        end

        def render_cached(endpoint, extra_key: nil)
          period = params[:period] || Trends::Api::BaseEndpointService::DEFAULT_PERIOD
          granularity = params[:granularity] || "daily"

          base_key = Trends::Cache::KeyBuilder.call(
            channel_id: @channel.id, endpoint: endpoint, period: period, granularity: granularity
          )
          # extra_key — для эндпоинтов с query-params-variant cache (pagination, group filter).
          key = extra_key ? "#{base_key}:#{extra_key}" : base_key

          ttl = Trends::Cache::KeyBuilder.ttl_for(period, endpoint: endpoint)
          race_ttl = Trends::Cache::KeyBuilder.race_condition_ttl_for(period, endpoint: endpoint)

          # FR-045 / SRS §10: monitoring surface для trends.api.*. Emit duration
          # (для p95 alert) + cache hit/miss (для hit_rate). Subscribers (Sentry/
          # StatsD/Prometheus) attach за кадром, этот код signalling only.
          cache_hit = true
          start_monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)

          payload = Rails.cache.fetch(key, expires_in: ttl, race_condition_ttl: race_ttl) do
            cache_hit = false
            yield
          end

          # T1-063 CR S-1: meta.access_level is user-derived, but the cache key is tier-agnostic
          # (channel/endpoint/period/granularity only) → the cached payload carries whichever
          # tier warmed the key. Recompute per-request and overwrite so a Free viewer (now in the
          # cache pool) can't read a cached "premium" access_level (wrong CTA / revenue). Only the
          # tier-invariant data series stays shared. Non-mutating merge — never touches the cached object.
          payload = override_access_level(payload)

          duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_monotonic) * 1000).round(2)

          ActiveSupport::Notifications.instrument(
            "trends.api.request",
            endpoint: endpoint,
            period: period,
            granularity: granularity,
            channel_id: @channel.id,
            cache_hit: cache_hit,
            duration_ms: duration_ms
          )

          response.set_header("X-Data-Freshness", payload.dig(:meta, :data_freshness).to_s)
          render json: payload
        end

        # T1-063 CR S-1: per-request access_level overwrite (see render_cached). Non-mutating —
        # returns a fresh hash so the shared cache entry is never altered.
        def override_access_level(payload)
          return payload unless payload.is_a?(Hash) && payload[:meta].is_a?(Hash)

          level = ChannelPolicy.new(current_user, @channel).access_level
          payload.merge(meta: payload[:meta].merge(access_level: level))
        end

        def render_invalid_params(exception)
          render json: {
            error: "invalid_params",
            message: exception.message
          }, status: :bad_request
        end
      end
    end
  end
end
