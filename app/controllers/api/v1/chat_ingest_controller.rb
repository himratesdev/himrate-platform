# frozen_string_literal: true

# TASK-110 FR-006..007: Buffered batch ingest для React fiber chat capture from extension.
# Per memory Q2 (PO 2026-05-06): chat = current channel React fiber NOT MutationObserver.
# Downstream chat archive pipeline = TASK-171 ClickHouse (separate epic).

module Api
  module V1
    class ChatIngestController < Api::BaseController
      before_action :authenticate_user!

      MAX_BATCH_SIZE = 100

      # POST /api/v1/chat/messages
      def create
        authorize User, :create?, policy_class: ChatIngestPolicy

        channel_slug = params[:channel_slug].to_s.strip
        messages = Array(params[:messages]).first(MAX_BATCH_SIZE)

        if channel_slug.blank? || messages.empty?
          render(json: { error: "invalid_payload", message: "channel_slug + messages required" }, status: :bad_request)
          return
        end

        # BUG-251.34 (CR iter1 Should-3): same Sidekiq 7 strict_args trap as SyncController#push —
        # `to_unsafe_h` returns HWIA which fails strict instance check. JSON round-trip → plain
        # Hash<String,_> recursively.
        ChatIngestWorker.perform_async(
          "channel_slug" => channel_slug,
          "messages" => JSON.parse(messages.map(&:to_unsafe_h).to_json)
        )

        render json: { accepted: messages.size }, status: :accepted
      end
    end
  end
end
