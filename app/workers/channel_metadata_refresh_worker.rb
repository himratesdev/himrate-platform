# frozen_string_literal: true

# TASK-251.3: keep monitored Channel metadata fresh from Helix /users.
#
# Channels are created by ChannelDiscoveryWorker / StreamOnlineWorker carrying only
# `login` + `is_monitored` → display_name / profile_image_url / broadcaster_type / description
# were null (UI and notifications showed blanks). This worker batch-fetches Helix /users
# (≤100 ids per request) for monitored channels that were never synced or are stale, fills
# the metadata, and stamps metadata_synced_at so each channel is refreshed at most once per
# STALE_AFTER. Bounded per run to cap Helix usage.

class ChannelMetadataRefreshWorker
  include Sidekiq::Job
  sidekiq_options queue: :monitoring, retry: 1

  HELIX_BATCH_SIZE = 100 # Helix /users accepts up to 100 ids per request
  STALE_AFTER = 7.days   # re-sync cadence per channel (names/avatars change rarely)
  MAX_PER_RUN = 1000     # cap Helix usage per run (≤10 calls); cron re-runs to finish backfill

  def perform
    return unless Flipper.enabled?(:stream_monitor)

    channels = channels_to_sync
    return if channels.empty?

    synced = 0
    channels.each_slice(HELIX_BATCH_SIZE) do |batch|
      by_id = (helix.get_users(ids: batch.map(&:twitch_id)) || []).index_by { |u| u["id"] }
      batch.each { |channel| synced += 1 if apply_metadata(channel, by_id[channel.twitch_id]) }
    end

    Rails.logger.info("ChannelMetadataRefreshWorker: synced #{synced}/#{channels.size} channels")
  end

  private

  def channels_to_sync
    Channel.monitored.active
           .where("metadata_synced_at IS NULL OR metadata_synced_at < ?", STALE_AFTER.ago)
           .order(Arel.sql("metadata_synced_at ASC NULLS FIRST"))
           .limit(MAX_PER_RUN)
           .to_a
  end

  # Stamp metadata_synced_at on every processed channel (even when Helix returns nothing —
  # banned/deleted user) so it isn't retried every run. Returns true when metadata was filled.
  def apply_metadata(channel, user)
    attrs = { metadata_synced_at: Time.current }
    if user
      attrs[:display_name] = user["display_name"].presence || channel.display_name
      attrs[:profile_image_url] = user["profile_image_url"].presence
      attrs[:broadcaster_type] = user["broadcaster_type"].presence
      attrs[:description] = user["description"]
    end

    channel.update!(attrs)
    user.present?
  rescue ActiveRecord::RecordInvalid => e
    Rails.logger.warn("ChannelMetadataRefreshWorker: #{channel.login} update failed (#{e.message})")
    false
  end

  def helix
    @helix ||= Twitch::HelixClient.new
  end
end
