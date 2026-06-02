# frozen_string_literal: true

# EPIC ML-FEATURE-EXTRACTOR PR7 — Maturity signals (3 features, EPIC closing).
#
# Per BFT 15_ML-Pipeline.md §3.2 Maturity signals — capped saturation features. These behave
# as diminishing-returns indicators: above the cap, additional history doesn't move the
# bot-detection probability. Caps are chosen so that they normalize the long-tail
# distribution and prevent the model from over-weighting "ancient" channels.
#
# - `account_age_days_capped`    — days since `channel.twitch_created_at`, capped at 365.
#                                    Established >1yr accounts behave similarly; the bot-signal
#                                    edge is in the first year.
# - `total_streams_capped`       — channel's completed-stream count over its lifetime,
#                                    capped at 200. Above 200 streams the streamer has a
#                                    well-established audience; further history is noise.
# - `total_hours_capped`         — sum of completed-stream durations (hours), capped at 1000.
#                                    1000h ≈ heavy-streamer territory; above is rare and
#                                    correlated with category not bot-risk.
#
# Data sources:
# - `Channel.twitch_created_at` (added in this PR's migration; populated by
#   `ChannelMetadataRefreshWorker` via `Channel#assign_helix_metadata` on each metadata sync —
#   organic backfill, no separate task)
# - `channel.streams.where.not(ended_at: nil)` — completed streams only (in-flight excluded).
#   `Stream` currently has no soft-delete column; if a future `Stream.deleted_at` is added,
#   this scope MUST be extended to exclude soft-deleted rows or both counts silently inflate
#   (CR-255 Nit-3).
#
# Cold-start semantics: nil + structured reason when source field is absent (e.g. brand-new
# channel that has not yet had its metadata refreshed → `twitch_created_at IS NULL`).
module Ml
  module Features
    class MaturitySignals
      AGE_CAP_DAYS = 365.0       # 1 year — saturation point for account-age signal
      STREAMS_CAP = 200          # established streamer threshold
      HOURS_CAP = 1_000.0        # heavy-streamer threshold

      def initialize(stream)
        @stream = stream
      end

      def call
        {
          account_age_days_capped: account_age_days_capped,
          total_streams_capped:    total_streams_capped,
          total_hours_capped:      total_hours_capped
        }
      end

      def insufficient_data_reasons
        @insufficient_data_reasons ||= {}
      end

      private

      def channel
        @channel ||= @stream.channel
      end

      # CR-255 Nit-2: pluck (started_at, ended_at) once per extraction and reuse the array for
      # both COUNT and SUM-of-durations — halves PG round-trips vs separate `.count + .sum`.
      # The slice is bounded by stream-history-of-channel — same order of magnitude as PR6's
      # `recent_streams` pluck (≤MAX_STREAM_HISTORY in steady-state for active channels;
      # potentially larger for back-catalog channels but still single-channel-bounded).
      def completed_stream_durations_sec
        @completed_stream_durations_sec ||= channel.streams
          .where.not(ended_at: nil)
          .pluck(:started_at, :ended_at)
          .map { |started_at, ended_at| (ended_at - started_at).to_f }
      end

      def account_age_days_capped
        twitch_created_at = channel.twitch_created_at
        if twitch_created_at.nil?
          insufficient_data_reasons[:account_age_days_capped] = "no_twitch_created_at_yet"
          return nil
        end
        age_days = (Time.current - twitch_created_at) / 1.day.to_f
        [ age_days, AGE_CAP_DAYS ].min.round(2)
      end

      def total_streams_capped
        # Integer count — `total_streams_capped` column stays integer (no precision loss).
        # Includes the current stream if it's already ended; that's correct — this feature
        # reflects channel total at extraction time.
        [ completed_stream_durations_sec.size, STREAMS_CAP ].min
      end

      def total_hours_capped
        # Float value persisted to numeric(8,2) (widened in 20260602060000 from PR1's int —
        # CR-255 Nit-1: int column would silently truncate fractional hours).
        hours = completed_stream_durations_sec.sum / 3600.0
        [ hours, HOURS_CAP ].min.round(2)
      end
    end
  end
end
