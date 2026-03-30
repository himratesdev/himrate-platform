# frozen_string_literal: true

# TASK-029 FR-004: Cold Start Guard.
# 5 tiers based on completed stream count.
# Confidence = min(1.0, stream_count / 10).

module TrustIndex
  class ColdStartGuard
    TIERS = [
      { status: "deep",            min_streams: 30 },
      { status: "full",            min_streams: 10 },
      { status: "provisional",     min_streams: 7 },
      { status: "provisional_low", min_streams: 3 },
      { status: "insufficient",    min_streams: 0 }
    ].freeze

    # Returns {status: String, confidence: Float, stream_count: Integer}
    def self.assess(channel)
      stream_count = channel.streams.where.not(ended_at: nil).count
      confidence = [ 1.0, stream_count / 10.0 ].min

      status = TIERS.find { |t| stream_count >= t[:min_streams] }[:status]

      { status: status, confidence: confidence.round(2), stream_count: stream_count }
    end
  end
end
