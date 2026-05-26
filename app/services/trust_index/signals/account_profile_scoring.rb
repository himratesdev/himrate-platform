# frozen_string_literal: true

# TASK-028 FR-011: Account Profile Scoring signal.
# Aggregate profile-based bot signals from per_user_bot_scores.
# Chatters with >= 3 profile flags = suspicious.

module TrustIndex
  module Signals
    class AccountProfileScoring < BaseSignal
      # TASK-251.W2b: only genuine bot-account traits count as flags. Streamer-presence flags
      # (description/banner/videos/last_broadcast nulls) were dropped from the scorer — they are
      # normal for viewers (not content creators) and falsely flagged ~50% of real chatters.
      PROFILE_KEYS = %w[
        profile_view_zero followers_zero account_age_7d account_age_30d
        follows_zero follows_excessive
      ].freeze

      # Zero-weight marker the scorer sets on every chatter whose profile was actually fetched.
      # Used as the denominator so a clean profile (no flags) counts as "profiled, not suspicious".
      PROFILE_PRESENT_KEY = "profile_present"

      MIN_FLAGS = 3

      def name = "Account Profile Scoring"
      def signal_type = "account_profile_scoring"

      def calculate(context)
        bot_scores = context[:bot_scores] || []

        return insufficient(reason: "no_bot_scores") if bot_scores.empty?

        # Filter to scores that have profile data in components
        with_profiles = bot_scores.select { |s| has_profile_data?(s[:components]) }

        return insufficient(reason: "no_profile_data") if with_profiles.empty?

        profile_suspicious = with_profiles.count { |s| count_profile_flags(s[:components]) >= MIN_FLAGS }
        total = with_profiles.size

        value = profile_suspicious.to_f / total
        confidence = [ 1.0, total / 30.0 ].min

        result(
          value: value,
          confidence: confidence,
          metadata: {
            total_with_profiles: total, profile_suspicious: profile_suspicious,
            total_chatters: bot_scores.size
          }
        )
      end

      private

      # "We have this chatter's profile" = the scorer set the zero-weight profile_present marker.
      # (Previously this checked for any flag key, so a clean profile looked like "no data" and was
      # excluded from the denominator — inflating the suspicious ratio.)
      def has_profile_data?(components)
        return false unless components.is_a?(Hash)

        components.key?(PROFILE_PRESENT_KEY) || components.key?(PROFILE_PRESENT_KEY.to_sym)
      end

      def count_profile_flags(components)
        return 0 unless components.is_a?(Hash)

        PROFILE_KEYS.count { |key| components.key?(key) || components.key?(key.to_sym) }
      end
    end
  end
end
