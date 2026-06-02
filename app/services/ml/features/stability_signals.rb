# frozen_string_literal: true

# EPIC ML-FEATURE-EXTRACTOR PR6 — Stability signals (3 features) per BFT 15_ML-Pipeline.md §3.2.
#
# Captures channel-level stability of two trusted-stream KPIs:
# - `trust_index_30d_std`  — std-dev of `TrustIndexHistory.trust_index_score` over the last
#                            N completed-stream histories (or N days, whichever is shorter).
#                            High std = TI bounces stream-to-stream — characteristic of audience
#                            instability (raids / paid spikes / cold-start jitter).
# - `chat_rate_30d_cv`     — CV (std/mean) of mean-chat-rate (msg/min) across the last N
#                            completed streams. Captures whether chat activity is consistent
#                            stream-to-stream; bot-floods вызывают spiky CV.
# - `viewer_retention_avg_sec` — DEFERRED. Genuine viewer retention requires per-viewer session
#                            tracking (join/part timestamps for ALL viewers, not just chatters).
#                            We don't have that signal-source built — chat-engaged viewers are
#                            biased toward active users, not the lurker majority. Separate
#                            viewer_session_tracking EPIC будет источником. Per
#                            [[feedback-no-throwaway-go-to-final-architecture]] we return nil
#                            + structured reason rather than a chat-biased proxy.
#
# Data sources:
# - `TrustIndexHistory` (PG) — already populated by TrustIndex::Engine on every stream-end + cron
# - `Clickhouse::ChatQueries.chat_rates_for_streams` (NEW) — batched per-stream count/min over
#   last N completed streams for the channel
#
# Window: last MAX_STREAM_HISTORY (30) completed streams ANDED with last MAX_DAYS_HISTORY (90)
# days — matches BFT §3.2 "30-stream OR 90-day" Reputation rolling window.
module Ml
  module Features
    class StabilitySignals
      MAX_STREAM_HISTORY = 30           # cap stream sample size — older = noise / outdated
      MAX_DAYS_HISTORY = 90             # outer time bound
      MIN_HISTORY_FOR_VARIANCE = 5      # ≥5 streams for meaningful std/CV estimate

      def initialize(stream)
        @stream = stream
      end

      def call
        {
          trust_index_30d_std:        trust_index_30d_std,
          chat_rate_30d_cv:           chat_rate_30d_cv,
          viewer_retention_avg_sec:   viewer_retention_avg_sec
        }
      end

      def insufficient_data_reasons
        @insufficient_data_reasons ||= {}
      end

      private

      # CR-253 M1 cleanup: anchor 90d window to `@stream.ended_at` (fallback `started_at`)
      # instead of call-time `Time.current`. Deterministic across delayed-queue / replay
      # / training backfill — same (stream_id, version) row always derives from same window.
      def extraction_anchor
        @extraction_anchor ||= @stream.ended_at || @stream.started_at
      end

      def window_start
        @window_start ||= extraction_anchor - MAX_DAYS_HISTORY.days
      end

      # Last MAX_STREAM_HISTORY trust_index_scores (stream-scoped — calculated_at on stream-end TI).
      # `TrustIndexHistory.stream_id` is nullable (TI can be channel-scoped too); we pick only
      # stream-scoped rows для stream-to-stream stability, not channel-aggregate noise.
      # CR-256 P1: both upper AND lower bounds anchored — `calculated_at BETWEEN window_start
      # AND extraction_anchor`. Without the upper bound a backfill replay would pick up TIH
      # rows for streams completed after `@stream.ended_at`.
      def trust_index_scores
        @trust_index_scores ||= TrustIndexHistory
          .for_channel(@stream.channel_id)
          .where.not(stream_id: nil)
          .where("calculated_at >= ? AND calculated_at <= ?", window_start, extraction_anchor)
          .order(calculated_at: :desc)
          .limit(MAX_STREAM_HISTORY)
          .pluck(:trust_index_score)
          .map(&:to_f)
      end

      # Last MAX_STREAM_HISTORY completed Stream rows for the channel (ended_at IS NOT NULL,
      # within 90d of extraction anchor). Ordered most-recent-first.
      # CR-256 P1: both upper AND lower bounds anchored.
      def recent_streams
        @recent_streams ||= Stream
          .for_channel(@stream.channel_id)
          .where.not(ended_at: nil)
          .where("ended_at >= ? AND ended_at <= ?", window_start, extraction_anchor)
          .order(ended_at: :desc)
          .limit(MAX_STREAM_HISTORY)
          .to_a
      end

      def trust_index_30d_std
        if trust_index_scores.size < MIN_HISTORY_FOR_VARIANCE
          insufficient_data_reasons[:trust_index_30d_std] = "insufficient_trust_index_history"
          return nil
        end
        mean = trust_index_scores.sum / trust_index_scores.size
        variance = trust_index_scores.sum { |v| (v - mean)**2 } / trust_index_scores.size
        Math.sqrt(variance).round(4)
      end

      def chat_rate_30d_cv
        if recent_streams.size < MIN_HISTORY_FOR_VARIANCE
          insufficient_data_reasons[:chat_rate_30d_cv] = "insufficient_stream_history"
          return nil
        end

        # Batched CH query: count privmsgs per stream + derive msg/min using stream duration.
        rates = chat_rates_per_stream
        if rates.size < MIN_HISTORY_FOR_VARIANCE
          insufficient_data_reasons[:chat_rate_30d_cv] = "insufficient_chat_data"
          return nil
        end

        mean = rates.sum / rates.size
        if mean.abs < 1e-6
          insufficient_data_reasons[:chat_rate_30d_cv] = "zero_mean_chat_rate"
          return nil
        end
        variance = rates.sum { |r| (r - mean)**2 } / rates.size
        (Math.sqrt(variance) / mean.abs).round(4)
      end

      # PR6 NOTE: Genuine viewer retention requires per-viewer session tracking (join/part for
      # ALL viewers including lurkers). Chat-based proxy biases against the lurker majority and
      # would mislead the ML model. Defer per [[feedback-no-throwaway-go-to-final-architecture]]
      # to the separate viewer_session_tracking EPIC. Structured-reason path matches the deferral
      # pattern used by `nlp_contextual_relevance_score` in `ChatSignals`.
      def viewer_retention_avg_sec
        insufficient_data_reasons[:viewer_retention_avg_sec] =
          "requires_viewer_session_tracking_separate_epic"
        nil
      end

      # Returns array of msg/min rates across `recent_streams`. Streams с zero-duration (started=ended)
      # OR zero messages are excluded — they'd produce 0/0 or 0 noise that biases the variance.
      def chat_rates_per_stream
        stream_ids = recent_streams.map(&:id)
        counts = Clickhouse::ChatQueries.privmsg_counts_for_streams(stream_ids)

        recent_streams.filter_map do |s|
          duration_sec = (s.ended_at - s.started_at).to_f
          next if duration_sec <= 0
          msgs = counts[s.id].to_i
          next if msgs.zero?
          (msgs.to_f / (duration_sec / 60.0)) # msg/min
        end
      end
    end
  end
end
