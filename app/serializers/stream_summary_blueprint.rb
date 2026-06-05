# frozen_string_literal: true

# TASK-085 FR-001 + BR-022 (ADR-085 D-3): Stream Summary Blueprinter serializer.
# Maps DB columns → business-friendly API field aliases (peak_viewers, duration_text, etc.).
# Internal DB keeps actual column names (ccv_peak, duration_ms, erv_final, game_name).
#
# Source: post_stream_reports table for ENDED streams, CcvSnapshot aggregates for LIVE
# streams (PR-A1 EPIC SCALE ARCHITECTURE Step 2 — streams.peak_ccv / avg_ccv / duration_ms
# columns dropped, derived via Stream#current_peak_ccv / current_avg_ccv / current_duration_ms).

class StreamSummaryBlueprint < Blueprinter::Base
  identifier :id, name: :session_id

  field :started_at do |stream|
    stream.started_at&.iso8601
  end

  field :ended_at do |stream|
    stream.ended_at&.iso8601
  end

  field :duration_seconds do |stream|
    duration_seconds_for(stream)
  end

  field :duration_text do |stream|
    Streams::DurationFormatter.format(seconds: duration_seconds_for(stream))
  end

  field :peak_viewers do |stream|
    stream.current_peak_ccv
  end

  field :avg_ccv do |stream|
    stream.current_avg_ccv
  end

  field :erv_percent_final do |stream|
    stream.post_stream_report&.erv_percent_final&.to_f
  end

  field :erv_count_final do |stream|
    stream.post_stream_report&.erv_final
  end

  field :category do |stream|
    stream.game_name
  end

  field :partial do |stream|
    stream.interrupted_at.present?
  end

  def self.duration_seconds_for(stream)
    duration_ms = stream.current_duration_ms
    return duration_ms / 1000 if duration_ms

    return nil unless stream.started_at && stream.ended_at

    (stream.ended_at - stream.started_at).to_i
  end
end
