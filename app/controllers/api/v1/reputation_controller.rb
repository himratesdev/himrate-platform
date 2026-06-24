# frozen_string_literal: true

# T1-065: Reputation history / trajectory endpoint. Thin controller — delegates all assembly to
# Reputation::HistoryService (mirrors TrustController). Free trust-summary: show_reputation_history?
# always allows (access-model v2 — the card is 100% free to the viewer), surface-agnostic.
module Api
  module V1
    class ReputationController < Api::BaseController
      include Channelable

      before_action :authenticate_user_optional!
      before_action :set_channel

      # GET /api/v1/channels/:channel_id/reputation/history
      def history
        authorize @channel, :show_reputation_history?

        payload = Reputation::HistoryService.cached_for(@channel)

        etag_value = Digest::MD5.hexdigest(payload.to_json)
        if stale?(etag: etag_value, public: true)
          render json: { data: payload }
        end
      end
    end
  end
end
