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
    MAX_PER_RUN = 100

    def perform
      return unless Flipper.enabled?(:social_footprint_index)

      channels = channels_to_sync
      return if channels.empty?

      synced = channels.sum { |channel| sync_channel(channel) }
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

    # Replace a channel's link set with its fresh Twitch socialMedias footprint (delete-then-insert in a
    # txn so a removed link disappears). TwitchSocials contract: nil = the GQL fetch FAILED → skip WITHOUT
    # stamping (retry next run, so a channel that has socials isn't frozen empty); [] = fetched OK, no
    # socials → stamp (0 links) to avoid a retry storm. Returns 1 if the channel was (re)synced, else 0.
    def sync_channel(channel)
      socials = SocialAnalytics::TwitchSocials.call(channel.login)
      return 0 if socials.nil? # transient GQL failure — no stamp, retry next run

      persist(channel, socials)
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
