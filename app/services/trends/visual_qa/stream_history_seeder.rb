# frozen_string_literal: true

# TASK-039 Visual QA: Creates N realistic stream rows с typed ccv/peak/game_name.
# Distribution: daily stream (1 per day), duration 3-5h, ccv 500-2500 (sin-based variation
# for lifelike trend), mix of game categories. Timestamps deterministic: today, today-1, today-N.

module Trends
  module VisualQa
    class StreamHistorySeeder
      GAME_CYCLE = [ "Just Chatting", "Just Chatting", "Fortnite", "Just Chatting", "Valorant" ].freeze

      def self.seed(channel:, days:)
        new(channel: channel, days: days).seed
      end

      def initialize(channel:, days:)
        @channel = channel
        @days = days
      end

      def seed
        streams = []
        @days.times do |offset|
          started_at = (today_end - offset.days).change(hour: 18, min: 0)
          ended_at = started_at + (3 + (offset % 3)).hours
          # Idempotent via (channel_id, started_at). Re-run returns existing stream.
          stream = Stream.find_or_create_by!(channel_id: @channel.id, started_at: started_at) do |s|
            s.ended_at = ended_at
            s.duration_ms = (ended_at - started_at).to_i * 1000
            s.peak_ccv = peak_ccv_for(offset)
            s.avg_ccv = avg_ccv_for(offset)
            s.title = "VQA Stream #{offset + 1}"
            s.game_name = GAME_CYCLE[offset % GAME_CYCLE.size]
            s.language = "en"
            s.is_mature = false
            s.merge_status = "separate"
          end
          streams << stream
        end
        streams
      end

      private

      def today_end
        Time.current.change(hour: 23, min: 0, sec: 0)
      end

      # Sin-wave с linear drift for realistic TI trend (ERV drifts upward over 30d).
      def avg_ccv_for(offset)
        base = 1000
        drift = (@days - offset) * 15 # rising CCV toward "today"
        noise = (::Math.sin(offset * 0.5) * 200).to_i
        [ base + drift + noise, 300 ].max
      end

      def peak_ccv_for(offset)
        (avg_ccv_for(offset) * 1.5).to_i
      end
    end
  end
end
