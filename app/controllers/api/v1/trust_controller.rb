# frozen_string_literal: true

# TASK-032 FR-001: Trust endpoint. Thin controller — delegates to Trust::ShowService.
# CR #4: Pundit show_trust? (always allows, all see headline).
# CR #5: Channelable concern for set_channel.
# CR #6: Business logic in Trust::ShowService.
# CR #10: Redis cache 30s.
# CR #11: ETag support.

module Api
  module V1
    class TrustController < Api::BaseController
      include Channelable

      before_action :authenticate_user_optional!
      before_action :set_channel

      # FR-001: GET /api/v1/channels/:id/trust
      def show
        authorize @channel, :show_trust?

        view = ChannelPolicy.new(current_user, @channel).serializer_view

        # CR #10: Redis cache 30s per channel + view
        payload = Rails.cache.fetch("trust:#{@channel.id}:#{view}", expires_in: 30.seconds) do
          Trust::ShowService.new(channel: @channel, view: view, user: current_user).call
        end

        # FR-011: ETag for conditional requests
        etag_value = Digest::MD5.hexdigest(payload.to_json)
        if stale?(etag: etag_value, public: view == :headline)
          render json: { data: payload }
        end
      end

      # TASK-035 FR-017: GET /api/v1/channels/:id/trust/history?period=30m|7d
      def history
        authorize @channel, :show_trust_history?

        period = params[:period] || "30m"

        # T1-060 FR-6: 7d history is premium-gated. Routed through Pundit (was an inline hard
        # 403) so the denial is surface-aware via resolve_error_code — extension viewers get
        # EXTENSION_DEEP_LOCKED (honest-empty), dashboard gets SUBSCRIPTION_REQUIRED. Upholds
        # the Pundit-only-paywall rule. Invalid (non-7d) periods skip this and fall to the 400 path.
        authorize @channel, :view_7d_trust_history? if period == "7d"

        payload = Rails.cache.fetch("trust_history:#{@channel.id}:#{period}", expires_in: 30.seconds) do
          Trust::HistoryService.new(channel: @channel, period: period).call
        end

        if payload[:error]
          render json: { error: payload[:error] }, status: :bad_request
          return
        end

        render json: { data: payload }
      end
    end
  end
end
