# frozen_string_literal: true

# TASK-039 Visual QA: creates active RehabilitationPenaltyEvent — feeds M6 module.
# Used только с 'streamer_with_rehab' profile. Penalty applied 10 days ago, partial
# progress toward 15 clean streams.
#
# Bonus accelerator bonus_pts_earned derived от TrustIndex::RehabilitationTracker
# reading TIH qualifying_signals_at_end (populated в Phase A3a). Here we don't populate
# those — bonus = 0 для baseline streamer_with_rehab. To test bonus badge visible,
# run Phase A3b QualifyingPercentileSnapshotWorker после seed.

module Trends
  module VisualQa
    class RehabilitationSeeder
      def self.seed(channel:, clean_streams:)
        new(channel: channel, clean_streams: clean_streams).seed
      end

      def initialize(channel:, clean_streams:)
        @channel = channel
        @clean_streams = clean_streams
      end

      def seed
        # Idempotent: один active (unresolved) penalty per channel. Re-run reuses existing.
        event = RehabilitationPenaltyEvent.where(channel_id: @channel.id, resolved_at: nil).first ||
                RehabilitationPenaltyEvent.create!(
                  channel_id: @channel.id,
                  initial_penalty: 20.0,
                  required_clean_streams: 15,
                  applied_at: 10.days.ago
                  # resolved_at nil → active. clean_streams_at_resolve set when complete.
                )
        [ event ]
      end
    end
  end
end
