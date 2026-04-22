# frozen_string_literal: true

# TASK-039 Phase C1: Trends API — nested under /api/v1/channels/:channel_id/trends/*.
# Actions: erv, trust_index, anomalies, components, rehabilitation (C1 subset).
# Stability, comparison, categories, weekday, insights → Phase C2.
#
# Controller тонкий (ai-dev-team/CLAUDE.md convention): params → endpoint service → render.
# Cache via Rails.cache.fetch с versioned key (FR-035) + race_condition_ttl (FR-037).
# Policy: authorize @channel, :view_trends_historical? (A2 FR-012).
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

        # GET /api/v1/channels/:channel_id/trends/rehabilitation
        def rehabilitation
          render_cached("rehabilitation") do
            Trends::Api::RehabilitationEndpointService.new(
              channel: @channel, period: params[:period] || "30d",
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

          ttl = Trends::Cache::KeyBuilder.ttl_for(period)
          race_ttl = Trends::Cache::KeyBuilder.race_condition_ttl_for(period)

          payload = Rails.cache.fetch(key, expires_in: ttl, race_condition_ttl: race_ttl) do
            yield
          end

          response.set_header("X-Data-Freshness", payload.dig(:meta, :data_freshness).to_s)
          render json: payload
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
