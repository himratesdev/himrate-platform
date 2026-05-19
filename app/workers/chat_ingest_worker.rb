# frozen_string_literal: true

# TASK-110 FR-007: Buffered batch ingest для React fiber chat capture messages from extension.
# Forwards к downstream chat archive pipeline (TASK-171 ClickHouse, separate epic — placeholder).
# Per FR-006, fiber NOT MutationObserver (Wave-3 finding, 7TV/FFZ pattern).
class ChatIngestWorker
  include Sidekiq::Job
  sidekiq_options queue: :chat, retry: 3

  # @param payload [Hash] {channel_slug:, messages: [{user_id, display_name, text, ts, badges}, ...]}
  def perform(payload)
    payload = payload.with_indifferent_access if payload.is_a?(Hash)
    channel_slug = payload[:channel_slug]
    messages = Array(payload[:messages])

    return if messages.empty?

    Rails.logger.info(
      "ChatIngestWorker: channel=#{channel_slug} batch_size=#{messages.size} " \
      "first_ts=#{messages.first&.dig(:ts)} last_ts=#{messages.last&.dig(:ts)}"
    )

    # TASK-171 placeholder: chat archive ClickHouse pipeline (separate epic).
    # For TASK-110 Day-0 — only logging + Sentry breadcrumb (telemetry validation chat capture works).
    # When TASK-171 ships → swap к ClickHouse insert_all batch + retention policy.
  end
end
