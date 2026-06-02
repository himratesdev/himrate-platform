# frozen_string_literal: true

# EPIC ML-FEATURE-EXTRACTOR PR4 — Account signals (4 features) per BFT 15_ML-Pipeline.md §3.2.
#
# Data sources:
# - PerUserBotScore (per-stream usernames — one row per unique chatter per stream)
# - ChatterProfile (global cache of GQL-fetched profile data: twitch_created_at,
#   followers_count, follows_count)
# - FollowerSnapshot (channel-level follower history) — для engagement_participation_ratio
#
# Per-feature cold-start: returns nil if source data insufficient. Records reasons в
# `insufficient_data_reasons` для observability.
module Ml
  module Features
    class AccountSignals
      MIN_PROFILES_FOR_RATIO_FEATURES = 10 # need ≥10 cached profiles for Gini/avg to be meaningful

      def initialize(stream)
        @stream = stream
      end

      def call
        {
          avg_account_age_days:                   avg_account_age_days,
          account_creation_date_clustering_gini:  account_creation_date_clustering_gini,
          profile_completeness_ratio:             profile_completeness_ratio,
          engagement_participation_ratio:         engagement_participation_ratio
        }
      end

      def insufficient_data_reasons
        @insufficient_data_reasons ||= {}
      end

      private

      # Cached profiles для chatters of THIS stream. Lookup via PerUserBotScore (per-stream
      # usernames) → ChatterProfile (global cache). Most chatters will have profiles fetched
      # by ChatterProfileRefreshWorker on a staleness cadence.
      def cached_profiles
        return @cached_profiles if defined?(@cached_profiles)

        usernames = @stream.per_user_bot_scores.distinct.pluck(:username).compact
        @cached_profiles = if usernames.empty?
                             []
        else
                             ChatterProfile.where(login: usernames).to_a
        end
      end

      def avg_account_age_days
        profiles = cached_profiles.select { |p| p.twitch_created_at.present? }
        return record_insufficient(:avg_account_age_days, "no_chatters") if cached_profiles.empty?
        return record_insufficient(:avg_account_age_days, "no_cached_profiles") if profiles.empty?
        return record_insufficient(:avg_account_age_days, "insufficient_profiles") if profiles.size < MIN_PROFILES_FOR_RATIO_FEATURES

        now = Time.current
        ages_days = profiles.map { |p| ((now - p.twitch_created_at) / 1.day).to_f }
        (ages_days.sum / ages_days.size).round(2)
      end

      # Gini coefficient of account creation date distribution. High Gini = creation dates
      # clustered (bot batch creation pattern — many accounts created в a narrow window).
      # Standard Gini formula on sorted ages (days since creation).
      def account_creation_date_clustering_gini
        profiles = cached_profiles.select { |p| p.twitch_created_at.present? }
        return record_insufficient(:account_creation_date_clustering_gini, "no_chatters") if cached_profiles.empty?
        return record_insufficient(:account_creation_date_clustering_gini, "no_cached_profiles") if profiles.empty?
        return record_insufficient(:account_creation_date_clustering_gini, "insufficient_profiles") if profiles.size < MIN_PROFILES_FOR_RATIO_FEATURES

        now = Time.current
        ages_days = profiles.map { |p| ((now - p.twitch_created_at) / 1.day).to_f }.sort
        gini_coefficient(ages_days).round(4)
      end

      # Profile completeness proxy: % chatters с both followers_count > 0 AND follows_count > 0.
      # NB: schema doesn't carry avatar/bio columns directly — BFT defines this as
      # "avatar + bio + follows" but with current cache (no avatar/bio) we use the available
      # presence signals. Refinement (proper avatar/bio fields) would extend the ChatterProfile
      # schema — separate PR; column shape stable.
      def profile_completeness_ratio
        return record_insufficient(:profile_completeness_ratio, "no_chatters") if cached_profiles.empty?
        return record_insufficient(:profile_completeness_ratio, "no_cached_profiles") if cached_profiles.size.zero?
        return record_insufficient(:profile_completeness_ratio, "insufficient_profiles") if cached_profiles.size < MIN_PROFILES_FOR_RATIO_FEATURES

        complete_count = cached_profiles.count do |p|
          p.followers_count.to_i.positive? && p.follows_count.to_i.positive?
        end
        (complete_count.to_f / cached_profiles.size).round(4)
      end

      # engagement_participation_ratio = unique chatters of stream / channel followers count.
      # Low ratio = most followers don't chat (bot-followers don't engage). High ratio = mostly
      # engaged audience. Uses latest FollowerSnapshot для denominator.
      def engagement_participation_ratio
        unique_chatters = @stream.per_user_bot_scores.distinct.count(:username).to_i
        return record_insufficient(:engagement_participation_ratio, "no_chatters") if unique_chatters.zero?

        # Channel doesn't declare `has_many :follower_snapshots` (FollowerSnapshot has the
        # belongs_to :channel inverse only); direct query is the canonical lookup.
        latest_snapshot = FollowerSnapshot.where(channel_id: @stream.channel_id).order(timestamp: :desc).first
        followers = latest_snapshot&.followers_count.to_i
        return record_insufficient(:engagement_participation_ratio, "no_follower_snapshot") if followers.zero?

        (unique_chatters.to_f / followers).round(4)
      end

      # Standard Gini coefficient on a sorted numeric array.
      # G = (sum_i((2i - n - 1) * x_i)) / (n * sum(x))
      # 0 = perfect equality, 1 = perfect inequality. Cluster of similar-age accounts → low
      # Gini (uniform distribution); diverse ages → higher Gini.
      def gini_coefficient(sorted_values)
        n = sorted_values.size
        return 0.0 if n.zero?

        total = sorted_values.sum
        return 0.0 if total.zero?

        weighted_sum = sorted_values.each_with_index.sum { |v, i| (2 * (i + 1) - n - 1) * v }
        (weighted_sum.to_f / (n * total)).abs
      end

      def record_insufficient(feature_key, reason)
        insufficient_data_reasons[feature_key] = reason
        nil
      end
    end
  end
end
