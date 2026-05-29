# frozen_string_literal: true

# TASK-028 FR-006: Channel Protection Score (CPS) signal.
# CPS 0-100 from 7 channel settings. Low CPS = vulnerable to bots.
# Signal value inverted: 1.0 - CPS/100 (high value = more suspicious).

module TrustIndex
  module Signals
    class ChannelProtectionScore < BaseSignal
      def name = "Channel Protection Score"
      def signal_type = "channel_protection_score"

      def calculate(context)
        config = context[:channel_protection_config]

        return result(value: 1.0, confidence: 0.0, metadata: { reason: "no_config" }) unless config

        cps = compute_cps(config)
        value = 1.0 - cps / 100.0

        freshness = config.respond_to?(:last_checked_at) && config.last_checked_at
        confidence = freshness && freshness > 1.hour.ago ? 1.0 : 0.5

        result(
          value: value,
          confidence: confidence,
          metadata: { cps: cps, components: cps_breakdown(config) }
        )
      end

      private

      # BUG-251.32: recalibrated CPS components matching the post-schema-shift fields Twitch
      # actually exposes today (chatSettings.requireVerifiedAccount replaces the removed
      # email/phone/min-age/restrict-first-timer subtype). Legacy boolean columns
      # (email_verification_required / phone_verification_required / minimum_account_age_minutes /
      # restrict_first_time_chatters) still readable on historical rows for back-compat but no
      # longer drive new CPS scoring — they always read as defaults (false / 0) for new rows.
      #
      # Weights re-anchored to total 100:
      #   follower-only mode:        0/15/30
      #   subscriber-only mode:      20
      #   slow mode:                 0/5/10/15
      #   emote-only mode:           5
      #   verified_account_required: 30
      #   ───────────────────────────
      #   max                       100
      def compute_cps(config)
        score = 0

        # Verified-account required (chatSettings.requireVerifiedAccount, 30 pts)
        score += 30 if config.verified_account_required

        # Follower-only mode (0/15/30 pts) — duration_min nil = no FO; 0 = FO any duration;
        # any positive = stricter FO window
        fol = config.followers_only_duration_min
        score += if fol.nil? || fol < 0
                   0
        elsif fol == 0
                   15
        else
                   30
        end

        # Subscriber-only mode (20 pts)
        score += 20 if config.subs_only_enabled

        # Slow mode (0/5/10/15 pts)
        slow = config.slow_mode_seconds || 0
        score += if slow <= 0
                   0
        elsif slow <= 10
                   5
        elsif slow <= 30
                   10
        else
                   15
        end

        # Emote-only mode (5 pts)
        score += 5 if config.emote_only_enabled

        [ score, 100 ].min
      end

      def cps_breakdown(config)
        {
          verified_account_required: config.verified_account_required,
          followers_only: config.followers_only_duration_min,
          subs_only: config.subs_only_enabled,
          slow_mode: config.slow_mode_seconds,
          emote_only: config.emote_only_enabled
        }
      end
    end
  end
end
