# frozen_string_literal: true

# TASK-039 Visual QA: Orchestrator для synthetic data seeding на staging/development.
# Создаёт полный channel → user → streams → TIH → TDA → anomalies → rehab chain
# для UI screenshot-based verification по wireframe Screens 1/2/3/10.
#
# Invoked через `rake trends:visual_qa:seed[login_prefix]`. Hard-refuse в production.
#
# Idempotent: checks VisualQaChannelSeed presence → no-op или update.
# Full teardown через .clear(login) — удаляет entire data chain + metadata row.

module Trends
  module VisualQa
    class DataSeeder
      class ProductionGuardTripped < StandardError; end
      class SeedError < StandardError; end

      CURRENT_SCHEMA_VERSION = 1

      # Supported profiles — каждый создаёт differently shaped test data:
      #   premium_tracked — активный канал, полный Trends UI visible (default)
      #   streamer_with_rehab — streamer OAuth, active rehabilitation_penalty, bonus points
      #   cold_start — <3 streams для InsufficientData testing
      PROFILES = %w[premium_tracked streamer_with_rehab cold_start].freeze

      def self.seed(login:, profile: "premium_tracked")
        new(login: login, profile: profile).seed
      end

      def self.clear(login:)
        new(login: login, profile: nil).clear
      end

      def initialize(login:, profile:)
        @login = login
        @profile = profile
      end

      def seed
        guard_against_production!
        raise SeedError, "Unknown profile '#{@profile}'" unless PROFILES.include?(@profile)

        channel = ChannelSeeder.ensure_channel(login: @login)
        stats = ActiveRecord::Base.transaction do
          run_profile(channel)
        end

        upsert_seed_metadata(channel, stats)
        ActiveSupport::Notifications.instrument(
          "trends.visual_qa.seed_completed",
          channel_id: channel.id, login: @login, profile: @profile, stats: stats
        )
        { channel: channel, stats: stats }
      end

      def clear
        guard_against_production!

        channel = Channel.find_by(login: @login)
        return { cleared: false, reason: "channel_not_found" } unless channel

        seed_record = VisualQaChannelSeed.find_by(channel_id: channel.id)
        unless seed_record
          return { cleared: false, reason: "not_a_vqa_seed" }
        end

        stats = ChannelSeeder.teardown_channel(channel: channel)
        seed_record.destroy!

        ActiveSupport::Notifications.instrument(
          "trends.visual_qa.clear_completed",
          channel_id: channel.id, login: @login, stats: stats
        )
        { cleared: true, stats: stats }
      end

      def status
        channel = Channel.find_by(login: @login)
        return { seeded: false, reason: "channel_not_found" } unless channel

        seed_record = VisualQaChannelSeed.find_by(channel_id: channel.id)
        return { seeded: false, reason: "not_a_vqa_seed" } unless seed_record

        {
          seeded: true,
          channel_id: channel.id,
          profile: seed_record.seed_profile,
          seeded_at: seed_record.seeded_at,
          schema_version: seed_record.schema_version,
          metadata: seed_record.metadata,
          live_counts: live_counts_for(channel)
        }
      end

      private

      def guard_against_production!
        return unless Rails.env.production?

        raise ProductionGuardTripped,
          "trends:visual_qa:* никогда не running в production. " \
          "Synthetic data + teardown — staging/development only."
      end

      def run_profile(channel)
        case @profile
        when "premium_tracked" then seed_premium_tracked(channel)
        when "streamer_with_rehab" then seed_streamer_with_rehab(channel)
        when "cold_start" then seed_cold_start(channel)
        end
      end

      # Profile: Premium user tracking сторонний channel с full Trends UI visible.
      # 30 days streams → TDA + TIH + anomalies + tier_changes. NO rehab.
      def seed_premium_tracked(channel)
        ChannelSeeder.ensure_premium_user_tracking(channel: channel)
        streams = StreamHistorySeeder.seed(channel: channel, days: 30)
        tih = TihHistorySeeder.seed(channel: channel, streams: streams)
        tda = TdaAggregateSeeder.seed(channel: channel, streams: streams)
        anomalies = AnomalyEventSeeder.seed(channel: channel, streams: streams, count: 3)
        tier_changes = TierChangeSeeder.seed(channel: channel, streams: streams, count: 2)

        {
          streams: streams.size,
          tih: tih.size,
          tda: tda.size,
          anomalies: anomalies.size,
          tier_changes: tier_changes.size,
          rehab_events: 0
        }
      end

      # Profile: Streamer на own channel с active rehabilitation (for M6 testing).
      def seed_streamer_with_rehab(channel)
        ChannelSeeder.ensure_streamer_oauth(channel: channel)
        streams = StreamHistorySeeder.seed(channel: channel, days: 30)
        tih = TihHistorySeeder.seed(channel: channel, streams: streams)
        tda = TdaAggregateSeeder.seed(channel: channel, streams: streams)
        tier_changes = TierChangeSeeder.seed(channel: channel, streams: streams, count: 1)
        rehab = RehabilitationSeeder.seed(channel: channel, clean_streams: 5)

        {
          streams: streams.size,
          tih: tih.size,
          tda: tda.size,
          anomalies: 0,
          tier_changes: tier_changes.size,
          rehab_events: rehab.size
        }
      end

      # Profile: <3 streams — triggers InsufficientData state для UI empty-state test.
      def seed_cold_start(channel)
        ChannelSeeder.ensure_premium_user_tracking(channel: channel)
        streams = StreamHistorySeeder.seed(channel: channel, days: 2)

        {
          streams: streams.size,
          tih: 0, tda: 0, anomalies: 0, tier_changes: 0, rehab_events: 0
        }
      end

      def upsert_seed_metadata(channel, stats)
        record = VisualQaChannelSeed.find_or_initialize_by(channel_id: channel.id)
        record.seed_profile = @profile
        record.seeded_at = Time.current
        record.metadata = stats
        record.schema_version = CURRENT_SCHEMA_VERSION
        record.save!
      end

      def live_counts_for(channel)
        {
          streams: channel.streams.count,
          tih: TrustIndexHistory.for_channel(channel.id).count,
          tda: TrendsDailyAggregate.where(channel_id: channel.id).count,
          anomalies: Anomaly.joins(:stream).where(streams: { channel_id: channel.id }).count,
          tier_changes: HsTierChangeEvent.for_channel(channel.id).count,
          rehab_events: RehabilitationPenaltyEvent.where(channel_id: channel.id).count
        }
      end
    end
  end
end
