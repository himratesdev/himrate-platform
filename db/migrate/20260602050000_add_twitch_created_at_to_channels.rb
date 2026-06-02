# frozen_string_literal: true

# EPIC ML-FEATURE-EXTRACTOR PR7: add `twitch_created_at` to channels.
#
# Helix `/users` returns `created_at` — the broadcaster's Twitch account creation date.
# We need it for `account_age_days_capped` ML feature (channel maturity signal: new accounts
# are slightly more likely to host bot-floods, established accounts are more stable). The
# field is nullable: `Channel#assign_helix_metadata` populates it on each metadata refresh
# (cadence `ChannelMetadataRefreshWorker::STALE_AFTER = 7 days`), so existing channels
# backfill organically without a blocking migration.
#
# Per [[feedback-build-complete-now]] — column added now, not «add when first row needs it»,
# so MaturitySignals can compute the feature as soon as the channel is refreshed.
class AddTwitchCreatedAtToChannels < ActiveRecord::Migration[8.0]
  def change
    add_column :channels, :twitch_created_at, :datetime
  end
end
