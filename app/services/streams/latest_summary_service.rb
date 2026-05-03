# frozen_string_literal: true

# TASK-085 FR-001..006: Stream Summary endpoint service.
# Exposes existing post_stream_reports data joined через streams (no new storage).
# Consumed by Api::V1::StreamsController#latest_summary action.

module Streams
  class LatestSummaryService
    NOT_FOUND = :not_found

    def initialize(channel:)
      @channel = channel
    end

    # Returns Hash {data:, meta:} or :not_found if no completed streams.
    def call
      stream = latest_completed_stream
      return NOT_FOUND unless stream

      payload = StreamSummaryBlueprint.render_as_hash(stream)
      meta = build_meta(stream)

      { data: payload, meta: meta }
    end

    private

    def latest_completed_stream
      @channel.streams
              .includes(:post_stream_report)
              .where.not(ended_at: nil)
              .order(ended_at: :desc)
              .first
    end

    # FR-006: meta.preliminary = true когда post_stream_reports row не существует
    # (PostStreamWorker batch не завершил). ERV-related fields в payload будут nil.
    def build_meta(stream)
      { preliminary: stream.post_stream_report.nil? }
    end
  end
end
