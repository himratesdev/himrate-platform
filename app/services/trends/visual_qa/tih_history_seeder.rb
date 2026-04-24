# frozen_string_literal: true

# TASK-039 Visual QA: creates TrustIndexHistory rows — один per stream — с realistic
# TI/ERV drift + classification. Feeds TDA aggregation + anomaly detection.
#
# Distribution:
#   TI: base 65 + linear rising to 85 across period + noise
#   ERV: base 72 + sine wave 60-90 (shows realistic fluctuation)
#   Classification: derived from TI (trusted ≥70, needs_review 50-69, suspicious 30-49, fraudulent <30)
#   signal_breakdown: synthetic 11 live signals + 3 reputation components с realistic values
#   confidence: 0.85 (full tier) для all seeded rows

module Trends
  module VisualQa
    class TihHistorySeeder
      LIVE_SIGNALS = %w[
        auth_ratio chatter_to_ccv ccv_step_function ccv_tier_clustering
        chat_behavior channel_protection_score cross_channel_presence
        known_bot_match raid_attribution ccv_chat_correlation account_profile_scoring
      ].freeze
      REPUTATION_COMPONENTS = %w[growth_rate follower_quality engagement_consistency].freeze

      def self.seed(channel:, streams:)
        new(channel: channel, streams: streams).seed
      end

      def initialize(channel:, streams:)
        @channel = channel
        @streams = streams
      end

      def seed
        total = @streams.size
        @streams.each_with_index.map do |stream, idx|
          ti = compute_ti(idx, total)
          erv = compute_erv(idx, total)
          classification = classify(ti)

          # Idempotent via stream_id — seeder creates ровно одну TIH per stream.
          TrustIndexHistory.find_or_create_by!(channel_id: @channel.id, stream_id: stream.id) do |tih|
            tih.trust_index_score = ti.round(2)
            tih.confidence = 0.85
            tih.classification = classification
            tih.cold_start_status = "full"
            tih.erv_percent = erv.round(2)
            tih.ccv = stream.avg_ccv
            tih.signal_breakdown = build_signal_breakdown(idx, total)
            tih.rehabilitation_penalty = 0.0
            tih.rehabilitation_bonus = 0.0
            tih.calculated_at = stream.ended_at
          end
        end
      end

      private

      def compute_ti(idx, total)
        progress = (total - idx).to_f / total  # 0..1 from oldest → newest
        base = 65 + (progress * 20) # rising 65 → 85
        noise = ::Math.sin(idx * 0.4) * 4
        (base + noise).clamp(30, 95)
      end

      def compute_erv(idx, total)
        progress = (total - idx).to_f / total
        base = 72 + (progress * 15) # 72 → 87
        noise = ::Math.sin(idx * 0.6 + 1) * 5
        (base + noise).clamp(30, 95)
      end

      def classify(ti)
        return "trusted" if ti >= 70
        return "needs_review" if ti >= 50
        return "suspicious" if ti >= 30

        "fraudulent"
      end

      # Synthetic signal_breakdown в shape expected production code — 14 components total.
      # Values drift с overall TI для consistent compound.
      def build_signal_breakdown(idx, total)
        scale = (total - idx).to_f / total
        live = LIVE_SIGNALS.each_with_object({}) do |sig, h|
          h[sig] = { "value" => (0.5 + scale * 0.4 + ::Math.sin(idx + sig.length) * 0.05).clamp(0, 1).round(3),
                     "confidence" => 0.85 }
        end
        reputation = REPUTATION_COMPONENTS.each_with_object({}) do |comp, h|
          h[comp] = (60 + scale * 25 + ::Math.sin(idx + comp.length) * 5).clamp(20, 95).round(1)
        end
        live.merge(reputation)
      end
    end
  end
end
