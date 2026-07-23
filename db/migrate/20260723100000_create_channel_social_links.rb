# frozen_string_literal: true

# Social-footprint index (SA-2): one row per (channel, linked social account), discovered from Twitch
# `channel.socialMedias` (keyless GQL, via SocialAnalytics::TwitchSocials). Persisting the footprint —
# instead of the per-view on-demand GQL — lets brand creator search FILTER by platform ("creators with a
# Telegram") and lets the blogger profile render its footprint instantly. Refreshed by
# Social::FootprintIndexWorker (bounded, once-per-channel-per-7-days, stamped via channels.social_synced_at).
#
# Descriptive only — this is identity/footprint, NOT a fraud signal.
#
# disable_ddl_transaction! for the CONCURRENTLY indexes (no table lock on the large channels table).
# Idempotent (if_not_exists) so a half-applied run re-applies cleanly.
class CreateChannelSocialLinks < ActiveRecord::Migration[8.0]
  disable_ddl_transaction!

  def up
    create_table :channel_social_links, id: :uuid, if_not_exists: true do |t|
      t.references :channel, type: :uuid, null: false, foreign_key: true, index: false
      t.string :platform, null: false # normalized: telegram/youtube/vk/instagram/tiktok/twitter/discord/rkn/…
      t.string :name                  # raw Twitch socialMedia.name (pre-normalization, for audit)
      t.string :title
      t.string :url, null: false
      t.string :handle
      t.boolean :analyzable, null: false, default: false
      t.timestamps
    end

    # One row per (channel, url) — a channel may link several platforms (and, rarely, two of one
    # platform), but never the same URL twice. The worker replaces a channel's set on each refresh.
    add_index :channel_social_links, %i[channel_id url], unique: true,
              name: "idx_channel_social_links_channel_url", algorithm: :concurrently, if_not_exists: true
    # "creators with a link on platform X" search filter.
    add_index :channel_social_links, :platform,
              name: "idx_channel_social_links_platform", algorithm: :concurrently, if_not_exists: true

    add_column :channels, :social_synced_at, :datetime unless column_exists?(:channels, :social_synced_at)
    add_index :channels, :social_synced_at,
              name: "idx_channels_social_synced_at", algorithm: :concurrently, if_not_exists: true
  end

  def down
    remove_index :channels, name: "idx_channels_social_synced_at", if_exists: true
    remove_column :channels, :social_synced_at, if_exists: true
    drop_table :channel_social_links, if_exists: true
  end
end
