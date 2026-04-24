# frozen_string_literal: true

# TASK-039 Visual QA: Ensures synthetic Channel + associated User(s) + Subscription +
# TrackedChannel chain exists (idempotent). Teardown removes entire chain.
#
# Login must start с 'vqa_test_' — prevents collision с real Twitch channel names.
# Production guard в DataSeeder orchestrator.

module Trends
  module VisualQa
    class ChannelSeeder
      LOGIN_PREFIX = "vqa_test_"
      # CR N-1: SHA1 digest full channel.id (16 chars, 16^16 combos) вместо
      # первых 8 chars — prevents email collision между parallel seeded channels
      # с совпадающими UUID prefix (возможно при 10+ parallel VQA runs).
      PREMIUM_USER_EMAIL_TEMPLATE = "vqa_premium_%s@himrate.test"
      STREAMER_USER_EMAIL_TEMPLATE = "vqa_streamer_%s@himrate.test"

      class InvalidLogin < StandardError; end

      def self.user_digest(channel)
        Digest::SHA1.hexdigest(channel.id)[0, 16]
      end

      def self.ensure_channel(login:)
        validate_login!(login)

        Channel.find_or_create_by!(login: login) do |c|
          c.twitch_id = "vqa_twitch_#{SecureRandom.hex(6)}"
          c.display_name = login.sub(LOGIN_PREFIX, "").capitalize
          c.broadcaster_type = "affiliate"
          c.is_monitored = true
          c.created_at = 30.days.ago # synthetic channel "age" для discovery_phase tests
        end
      end

      # Ensures premium user tracking этого канала. Creates User (tier='premium')
      # + Subscription (premium active) + TrackedChannel link. Idempotent.
      def self.ensure_premium_user_tracking(channel:)
        digest = user_digest(channel)
        user = User.find_or_create_by!(email: PREMIUM_USER_EMAIL_TEMPLATE % digest) do |u|
          u.username = "vqa_premium_#{digest}"
          u.role = "viewer"
          u.tier = "premium"
        end

        Subscription.find_or_create_by!(user_id: user.id, tier: "premium", is_active: true) do |s|
          s.plan_type = "per_channel"
          s.started_at = 14.days.ago
        end

        TrackedChannel.find_or_create_by!(user_id: user.id, channel_id: channel.id) do |tc|
          tc.tracking_enabled = true
          tc.added_at = 14.days.ago
        end

        user
      end

      # Ensures streamer OAuth linkage — is_broadcaster auth_provider + matching Twitch id.
      # Used для M6 rehab tests (streamer on own channel view).
      def self.ensure_streamer_oauth(channel:)
        digest = user_digest(channel)
        user = User.find_or_create_by!(email: STREAMER_USER_EMAIL_TEMPLATE % digest) do |u|
          u.username = "vqa_streamer_#{digest}"
          u.role = "streamer"
          u.tier = "free"
        end

        AuthProvider.find_or_create_by!(user_id: user.id, provider: "twitch", provider_id: channel.twitch_id) do |ap|
          ap.is_broadcaster = true
          ap.scopes = [ "channel:read:subscriptions" ]
        end

        user
      end

      # Complete teardown: removes all VQA-seeded synthetic data downstream.
      # Order matters — FKs dictate reverse creation sequence.
      #
      # CR N-4: Explicit delete_all (vs полагаться на dependent: :destroy на Channel
      # model) is intentional. Channel model в app code имеет some `dependent:` declared,
      # but not для все VQA-seeded associations (e.g. FollowerSnapshot, AnomalyAttribution
      # в chain, synthetic Users). Ручной delete_all = explicit contract независимо от
      # future Channel model refactors. channel.destroy! в конце covers FollowerSnapshots
      # + TrackingRequest + other model-declared dependents.
      def self.teardown_channel(channel:)
        digest = user_digest(channel)
        stats = {}

        stats[:anomaly_attributions] = AnomalyAttribution
          .joins(anomaly: :stream)
          .where(streams: { channel_id: channel.id }).delete_all
        stats[:anomalies] = Anomaly.joins(:stream).where(streams: { channel_id: channel.id }).delete_all
        stats[:tih] = TrustIndexHistory.for_channel(channel.id).delete_all
        stats[:tda] = TrendsDailyAggregate.where(channel_id: channel.id).delete_all
        stats[:tier_changes] = HsTierChangeEvent.for_channel(channel.id).delete_all
        stats[:rehab_events] = RehabilitationPenaltyEvent.where(channel_id: channel.id).delete_all
        stats[:follower_snapshots] = FollowerSnapshot.where(channel_id: channel.id).delete_all
        stats[:streams] = channel.streams.delete_all
        stats[:tracked_channels] = TrackedChannel.where(channel_id: channel.id).delete_all

        synthetic_user_emails = [
          PREMIUM_USER_EMAIL_TEMPLATE % digest,
          STREAMER_USER_EMAIL_TEMPLATE % digest
        ]
        synthetic_users = User.where(email: synthetic_user_emails)
        stats[:subscriptions] = Subscription.where(user_id: synthetic_users.select(:id)).delete_all
        stats[:auth_providers] = AuthProvider.where(user_id: synthetic_users.select(:id)).delete_all
        stats[:users] = synthetic_users.delete_all

        stats[:channel] = channel.destroy! ? 1 : 0

        stats
      end

      def self.validate_login!(login)
        unless login.start_with?(LOGIN_PREFIX)
          raise InvalidLogin,
            "Visual QA channel login must start with '#{LOGIN_PREFIX}' " \
            "(safety — prevents collision с real Twitch usernames). Got: '#{login}'"
        end
      end
    end
  end
end
