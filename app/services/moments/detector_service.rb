# frozen_string_literal: true

module Moments
  # Screen 07 «Лучшие моменты» — detects the chat-activity peaks of a FINISHED stream from the
  # existing per-minute ClickHouse MV (mv_stream_minute_target via ChatQueries.chat_rate, <200ms).
  # Pure compute-on-read over immutable data (the stream is finished) — the controller caches.
  #
  # Honest scope (DSV 2026-07-21, wave3-moments/SCOPING.md):
  #   - chat peaks = REAL and complete (every IRC message is ingested);
  #   - «Донаты» moments are NOT built: pva_engagement_events is a per-USER client-capture log of
  #     extension users, not the channel's donation feed — faking channel-wide donations from it
  #     would violate the no-mock rule. Deferred until a real EventSub/Helix donations source.
  #   - AI categories (клатчи/смешное) have no engine — deferred (frontend hides those chips).
  class DetectorService
    MIN_MULTIPLIER = 2.0   # a minute must be ≥2× the stream's median chat rate
    MIN_MESSAGES = 5       # absolute floor — a 2-msg/min stream's "spike" of 4 msgs is noise
    TOP_N = 8              # design shows a bounded moments list
    MERGE_GAP_MINUTES = 1  # adjacent spike minutes merge into one moment window

    def initialize(stream)
      @stream = stream
    end

    # => [ { offset_sec:, at:, duration_sec:, msg_count:, multiplier:, type: "chat_peak" }, ... ]
    def call
      histogram = Clickhouse::ChatQueries.chat_rate(@stream, @stream.started_at)
      return [] if histogram.empty?

      counts = histogram.map { |h| h[:msg_count] }.reject(&:zero?).sort
      return [] if counts.empty?

      baseline = median(counts)
      threshold = [ (baseline * MIN_MULTIPLIER).ceil, MIN_MESSAGES ].max

      spikes = histogram.select { |h| h[:msg_count] >= threshold }
      windows = merge_adjacent(spikes)

      windows
        .map { |w| build_moment(w, baseline) }
        .sort_by { |m| -m[:multiplier] }
        .first(TOP_N)
        .sort_by { |m| m[:offset_sec] }
    end

    private

    def median(sorted)
      mid = sorted.size / 2
      sorted.size.odd? ? sorted[mid].to_f : (sorted[mid - 1] + sorted[mid]) / 2.0
    end

    # Merge spike minutes that are ≤MERGE_GAP_MINUTES apart into windows (a hype moment spans minutes).
    def merge_adjacent(spikes)
      spikes.each_with_object([]) do |point, windows|
        last = windows.last
        if last && (point[:timestamp] - last[:to]) <= (MERGE_GAP_MINUTES * 60)
          last[:to] = point[:timestamp]
          last[:peak] = [ last[:peak], point[:msg_count] ].max
          last[:total] += point[:msg_count]
        else
          windows << { from: point[:timestamp], to: point[:timestamp], peak: point[:msg_count], total: point[:msg_count] }
        end
      end
    end

    def build_moment(window, baseline)
      offset = (window[:from] - @stream.started_at).to_i
      {
        type: "chat_peak",
        offset_sec: offset.clamp(0, 10**7),
        at: window[:from].utc.iso8601,
        duration_sec: (window[:to] - window[:from]).to_i + 60, # window covers its last minute
        msg_count: window[:total],
        multiplier: baseline.positive? ? (window[:peak] / baseline).round(1) : nil
      }
    end
  end
end
