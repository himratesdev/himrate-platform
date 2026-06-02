# frozen_string_literal: true

class Channel < ApplicationRecord
  has_many :streams, dependent: :destroy
  has_many :tracked_channels, dependent: :destroy
  has_many :watchlist_channels, dependent: :destroy
  has_many :users, through: :tracked_channels
  has_many :trust_index_histories, dependent: :destroy
  has_one :streamer_reputation, dependent: :destroy
  has_one :channel_protection_config, dependent: :destroy
  # SF-5 CR iter 2: delete_all vs destroy — aggregate data без callbacks,
  # scale 1825 rows/channel × 100k channels × 5y → single SQL DELETE vs N+1.
  has_many :trends_daily_aggregates, dependent: :delete_all

  validates :twitch_id, presence: true, uniqueness: true
  validates :login, presence: true

  scope :active, -> { where(deleted_at: nil) }
  scope :monitored, -> { where(is_monitored: true) }
  # TASK-251.12: pinned = curated set, guaranteed-monitored + protected from the discovery prune.
  scope :pinned, -> { where(is_pinned: true) }

  # TASK-032 CR #5: channel_live? as instance method (DRY)
  def live?
    streams.where(ended_at: nil).exists?
  end

  # TASK-251.12: map a Helix /users record onto this channel's metadata columns. Shared by
  # ChannelMetadataRefreshWorker (TASK-251.3) and Channels::CuratedSeeder (TASK-251.12) so the
  # mapping has a single source of truth. Keeps the existing display_name/avatar when Helix returns
  # blank (don't lose data); broadcaster_type/description reflect the current Helix value as-is
  # ("" = normal user / cleared bio is meaningful, must not stay stale). Stamps metadata_synced_at.
  # The caller persists (save!/update!).
  def assign_helix_metadata(user)
    # `created_at` may be missing on a banned/deleted user response; keep previous value when
    # Helix omits it (string presence rejects nil + empty — both safe to skip `Time.parse`).
    # PR7 (MLFE EPIC): twitch_created_at is the broadcaster's Twitch-side account creation
    # date — drives MaturitySignals.account_age_days_capped.
    helix_created_at = user["created_at"].presence&.then { |raw| Time.parse(raw) }

    assign_attributes(
      display_name: user["display_name"].presence || display_name,
      profile_image_url: user["profile_image_url"].presence || profile_image_url,
      broadcaster_type: user["broadcaster_type"],
      description: user["description"],
      twitch_created_at: helix_created_at || twitch_created_at,
      metadata_synced_at: Time.current
    )
  end
end
