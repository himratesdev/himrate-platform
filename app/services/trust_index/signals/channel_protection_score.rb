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

      def compute_cps(config)
        score = 0

        # Phone verification (25 pts)
        score += 25 if config.phone_verification_required

        # Email verification (20 pts)
        score += 20 if config.email_verification_required

        # Follower-only mode (0/5/15 pts)
        fol = config.followers_only_duration_min
        score += if fol.nil? || fol < 0
                   0
        elsif fol == 0
                   5
        else
                   15
        end

        # Minimum account age (0/5/10/15 pts)
        age = config.minimum_account_age_minutes || 0
        score += if age <= 0
                   0
        elsif age < 60
                   5
        elsif age < 1440
                   10
        else
                   15
        end

        # Subscriber-only mode (10 pts)
        score += 10 if config.subs_only_enabled

        # Slow mode (0/3/5/8 pts)
        slow = config.slow_mode_seconds || 0
        score += if slow <= 0
                   0
        elsif slow <= 10
                   3
        elsif slow <= 30
                   5
        else
                   8
        end

        # Restrict first-time chatters (7 pts)
        score += 7 if config.restrict_first_time_chatters

        [ score, 100 ].min
      end

      def cps_breakdown(config)
        {
          phone_verification: config.phone_verification_required,
          email_verification: config.email_verification_required,
          followers_only: config.followers_only_duration_min,
          min_account_age: config.minimum_account_age_minutes,
          subs_only: config.subs_only_enabled,
          slow_mode: config.slow_mode_seconds,
          restrict_first_timers: config.restrict_first_time_chatters
        }
      end
    end
  end
end
