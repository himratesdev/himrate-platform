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

      # Stream's chatter usernames from PerUserBotScore. CR-251 N2: the (stream_id, username)
      # UNIQUE constraint (migration 20260423112233_add_unique_index_per_user_bot_scores) means
      # pluck already returns distinct values — no extra `.distinct` needed.
      def stream_chatter_usernames
        @stream_chatter_usernames ||= @stream.per_user_bot_scores.pluck(:username).compact
      end

      # Cached profiles для chatters of THIS stream. Lookup via PerUserBotScore (per-stream
      # usernames) → ChatterProfile (global cache). Most chatters will have profiles fetched
      # by ChatterProfileRefreshWorker on a staleness cadence.
      def cached_profiles
        @cached_profiles ||= if stream_chatter_usernames.empty?
                               []
        else
                               ChatterProfile.where(login: stream_chatter_usernames).to_a
        end
      end

      # CR-251 M1: explicit guard ladder distinguishing 3 distinct cold-start cases:
      # 1) `no_chatters` — stream has no PerUserBotScore rows (chatters never scored)
      # 2) `no_cached_profiles` — chatters exist, но ChatterProfile cache miss for all of them
      # 3) `insufficient_profiles` — have profiles, но fewer than MIN for variance-based stats
      # Each branch reachable; spec asserts all three.
      def insufficient_account_data_reason
        return "no_chatters" if stream_chatter_usernames.empty?
        return "no_cached_profiles" if cached_profiles.empty?
        return "insufficient_profiles" if cached_profiles.size < MIN_PROFILES_FOR_RATIO_FEATURES

        nil
      end

      def profiles_with_creation_date
        @profiles_with_creation_date ||= cached_profiles.select { |p| p.twitch_created_at.present? }
      end

      def avg_account_age_days
        reason = insufficient_account_data_reason
        return record_insufficient(:avg_account_age_days, reason) if reason

        profiles = profiles_with_creation_date
        return record_insufficient(:avg_account_age_days, "no_profiles_with_creation_date") if profiles.empty?

        now = Time.current
        ages_days = profiles.map { |p| ((now - p.twitch_created_at) / 1.day).to_f }
        (ages_days.sum / ages_days.size).round(2)
      end

      # Gini coefficient of account creation date distribution. High Gini = creation dates
      # clustered (bot batch creation pattern — many accounts created в a narrow window).
      # Standard Gini formula on sorted ages (days since creation).
      def account_creation_date_clustering_gini
        reason = insufficient_account_data_reason
        return record_insufficient(:account_creation_date_clustering_gini, reason) if reason

        profiles = profiles_with_creation_date
        return record_insufficient(:account_creation_date_clustering_gini, "no_profiles_with_creation_date") if profiles.empty?

        now = Time.current
        ages_days = profiles.map { |p| ((now - p.twitch_created_at) / 1.day).to_f }.sort
        gini_coefficient(ages_days).round(4)
      end

      # Profile completeness proxy: % chatters с both followers_count > 0 AND follows_count > 0.
      # NB: schema doesn't carry avatar/bio columns directly — BFT defines this as
      # "avatar + bio + follows" but with current cache (no avatar/bio) we use the available
      # presence signals. CR-251 S2: refinement (proper avatar/bio fields) requires
      # ChatterProfile schema extension — tracked as separate follow-up. Column shape stable;
      # ML model retrains когда schema-extended column lands.
      def profile_completeness_ratio
        reason = insufficient_account_data_reason
        return record_insufficient(:profile_completeness_ratio, reason) if reason

        complete_count = cached_profiles.count do |p|
          p.followers_count.to_i.positive? && p.follows_count.to_i.positive?
        end
        (complete_count.to_f / cached_profiles.size).round(4)
      end

      # engagement_participation_ratio = unique chatters of stream / channel followers count.
      # Low ratio = most followers don't chat (bot-followers don't engage). High ratio = mostly
      # engaged audience. Uses latest FollowerSnapshot для denominator.
      #
      # CR-251 S1: distinguish "no FollowerSnapshot ever recorded" (channel not yet snapshotted)
      # from "snapshot exists but followers_count = 0" (brand-new channel). Both should be nil
      # but with different reasons for observability.
      def engagement_participation_ratio
        return record_insufficient(:engagement_participation_ratio, "no_chatters") if stream_chatter_usernames.empty?

        # Channel doesn't declare `has_many :follower_snapshots` (FollowerSnapshot has the
        # belongs_to :channel inverse only); direct query is the canonical lookup.
        latest_snapshot = FollowerSnapshot.where(channel_id: @stream.channel_id).order(timestamp: :desc).first
        return record_insufficient(:engagement_participation_ratio, "no_follower_snapshot") if latest_snapshot.nil?

        followers = latest_snapshot.followers_count.to_i
        return record_insufficient(:engagement_participation_ratio, "zero_followers") if followers.zero?

        (stream_chatter_usernames.size.to_f / followers).round(4)
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
