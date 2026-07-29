# frozen_string_literal: true

module Social
  # SA-2 social-footprint index refresh. Keeps each monitored channel's set of linked social accounts
  # (channel_social_links) fresh from Twitch `channel.socialMedias` (keyless GQL via TwitchSocials).
  #
  # Bounded + stale-guarded (mirrors ChannelMetadataRefreshWorker / FollowerSnapshotWorker): each run
  # syncs at most MAX_PER_RUN channels that were never synced or are older than STALE_AFTER, ordered
  # oldest-first, and stamps channels.social_synced_at so each channel refreshes at most once per cadence.
  # The cron (every 15 min) clears the daily backlog in bursts then idles (stale-guard selects 0).
  # Gated by Flipper[:social_footprint_index] so it's enabled per-env post-deploy.
  #
  # Scale: 4476 monitored channels ÷ 7-day cadence ≈ 640/day; MAX_PER_RUN=100 × 96 runs/day = 9600/day
  # capacity → covers the pool ~15× (and 10× growth). One GQL channel_about per channel, on :long_running
  # (external HTTP with retry-sleep — never Puma). Descriptive footprint only, NO fraud signal.
  class FootprintIndexWorker
    include Sidekiq::Job
    sidekiq_options queue: :long_running, retry: 1

    STALE_AFTER = 7.days
    MAX_PER_RUN = 120
    # BATCH the channel_about GQL calls (≤ GqlClient MAX_BATCH_SIZE 35). A per-channel loop of 100 tight
    # calls rate-limited Twitch (~50% partial "service error" / nil); one batch request per 30 channels is
    # 1/30th the requests → no rate-limit, and far faster. 120/run = 4 batch requests every 15 min →
    # 11,520/day capacity (covers the pool + 10× growth) with a tiny GQL footprint.
    BATCH_SIZE = 30

    def perform
      return unless Flipper.enabled?(:social_footprint_index)

      channels = channels_to_sync
      return if channels.empty?

      synced = channels.each_slice(BATCH_SIZE).sum { |slice| sync_batch(slice) }
      Rails.logger.info("Social::FootprintIndexWorker: synced #{synced}/#{channels.size} channels")
    end

    private

    def channels_to_sync
      # `.monitored.active` (not inline where) so the query predicate stays provably in lockstep with the
      # partial index `idx_channels_social_synced_at` (WHERE is_monitored=true AND deleted_at IS NULL).
      Channel.monitored.active
             .where("social_synced_at IS NULL OR social_synced_at < ?", STALE_AFTER.ago)
             .order(Arel.sql("social_synced_at ASC NULLS FIRST"))
             .limit(MAX_PER_RUN)
    end

    # One GQL batch → the channel_about for every login in the slice → normalize + persist each.
    def sync_batch(channels)
      abouts = Twitch::GqlClient.new.batch_channel_about(logins: channels.map(&:login))
      channels.sum { |channel| sync_channel(channel, abouts[channel.login]) }
    rescue StandardError => e
      Rails.logger.warn("Social::FootprintIndexWorker: batch failed (#{e.class}: #{e.message&.slice(0, 120)}) — retry next run")
      0
    end

    # Persist a channel's footprint from one batch slot. batch_channel_about gives us three states:
    #   nil        → the batch slot failed (transient) → skip WITHOUT stamping (retry next run).
    #   :not_found → dead/renamed/banned channel (200 but user null) → stamp EMPTY so it drops out of the
    #                NULLS-FIRST queue for STALE_AFTER instead of churning every run (the bulk of the
    #                monitored set's apparent failures). Same «stamp a definitively-gone id» pattern as
    #                ChannelMetadataRefreshWorker#isolate_bad_id.
    #   hash       → normalize via from_about. nil socials there = a null socialMedias FIELD on a present
    #                user (partial GQL failure under load) → skip (retry); [] = genuinely none → stamp.
    # Returns 1 if the channel was (re)synced/stamped, else 0.
    def sync_channel(channel, result)
      return 0 if result.nil? # transient batch-slot failure — retry next run, no stamp

      socials = result == :not_found ? [] : SocialAnalytics::TwitchSocials.from_about(result)
      return 0 if socials.nil? # partial socialMedias-field failure — retry next run, no stamp

      persist(channel, socials) # [] (dead / genuinely-no-socials) stamps 0 links → drops out for STALE_AFTER
      1
    rescue StandardError => e
      Rails.logger.warn("Social::FootprintIndexWorker[#{channel.login}]: #{e.class}: #{e.message&.slice(0, 140)}")
      0
    end

    def persist(channel, socials)
      rows = dedupe_by_url(socials)
      ActiveRecord::Base.transaction do
        channel.social_links.delete_all
        rows.each do |s|
          channel.social_links.create!(
            platform: s[:platform], title: s[:title], url: s[:url],
            handle: s[:handle], analyzable: s[:analyzable]
          )
        end
        channel.update_column(:social_synced_at, Time.current) # rubocop:disable Rails/SkipsModelValidations
      end
    end

    # Twitch can (rarely) list the same URL twice; the (channel_id, url) unique index would raise on the
    # second insert and abort the whole channel. Dedupe on url first (blank urls dropped).
    def dedupe_by_url(socials)
      socials.reject { |s| s[:url].blank? }.uniq { |s| s[:url] }
    end
  end
end
