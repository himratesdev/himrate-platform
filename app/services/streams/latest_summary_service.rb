# frozen_string_literal: true

# TASK-085 FR-001..006: Stream Summary endpoint service.
# Exposes existing post_stream_reports data joined через streams (no new storage).
# Consumed by Api::V1::StreamsController#latest_summary action.

module Streams
  class LatestSummaryService
    # CR N-5: Symbol sentinel chosen over Result struct — only two outcomes (success Hash | not-found).
    # Caller (StreamsController#latest_summary) does `result == NOT_FOUND` check, simple binary branch.
    # Result/Dry::Monads abstraction would be overkill for this surface area.
    NOT_FOUND = :not_found

    def initialize(channel:)
      @channel = channel
    end

    # Returns Hash {data:, meta:} or :not_found if no completed streams.
    def call
      stream = latest_completed_stream
      return NOT_FOUND unless stream

      payload = StreamSummaryBlueprint.render_as_hash(stream)
      payload.merge!(v2_verdict_block(stream)) if v2_engine?
      meta = build_meta(stream)

      { data: payload, meta: meta }
    end

    private

    # T1-074 surface-audit (HIGH): under the v2 cutover PSRs stop-write erv_percent_final —
    # the blueprint field is permanently nil and the surface carried NO v2 verdict at all.
    # Enrich additively from the stream's final v2 TIH (ONE query — single-stream endpoint);
    # erv_count_final stays the blueprint's (PSR erv_final = the same v2 count).
    def v2_verdict_block(stream)
      tih = stream.trust_index_histories.where(engine_version: "v2").order(calculated_at: :desc).first
      band = if tih&.band_row
        { row: tih.band_row, color: tih.band_color,
          label_key: TrustIndex::V2::BandClassifier.label_key_for(tih.band_row), sub: tih.band_sub }
      else
        { row: 5, color: "grey", label_key: "band.grey_insufficient", sub: nil }
      end
      {
        authenticity: tih&.authenticity&.to_f,
        band: band,
        engine_version: "v2"
      }
    end

    def v2_engine?
      Flipper.enabled?(:ti_v2_engine)
    rescue StandardError
      false
    end

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
