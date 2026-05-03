# frozen_string_literal: true

# TASK-085 FR-001 + BR-022 (ADR-085 D-3): Stream Summary Blueprinter serializer.
# Maps DB columns → business-friendly API field aliases (peak_viewers, duration_text, etc.).
# Internal DB keeps actual column names (ccv_peak, duration_ms, erv_final, game_name).
#
# Source: post_stream_reports table (joined через streams.includes(:post_stream_report)).
# Fallback: streams.peak_ccv / avg_ccv если post_stream_report nil (preliminary state EC-5).

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
    stream.post_stream_report&.ccv_peak || stream.peak_ccv
  end

  field :avg_ccv do |stream|
    stream.post_stream_report&.ccv_avg || stream.avg_ccv
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
    return stream.duration_ms / 1000 if stream.duration_ms
    return nil unless stream.started_at && stream.ended_at

    (stream.ended_at - stream.started_at).to_i
  end
end
