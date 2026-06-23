# frozen_string_literal: true

class User < ApplicationRecord
  include Flipper::Identifier
  has_many :auth_providers, dependent: :destroy
  has_many :subscriptions, dependent: :destroy
  has_many :tracked_channels, dependent: :destroy
  has_many :channels, through: :tracked_channels
  has_many :watchlists, dependent: :destroy
  has_many :sessions, dependent: :destroy
  has_many :notifications, dependent: :destroy
  has_many :score_disputes, dependent: :destroy
  has_many :pdf_reports, dependent: :destroy
  has_many :api_keys, dependent: :destroy
  has_many :team_memberships, dependent: :destroy
  has_many :owned_team_memberships, class_name: "TeamMembership", foreign_key: :team_owner_id, dependent: :destroy

  # TASK-113 PVA (BE-1): query-only ассоциации. Без dependent: — User soft-deleted (deleted_at),
  # AR-cascade не сработал бы; удаление обеспечивают DB on_delete: :cascade (hard-delete) +
  # M15 (GDPR delete, BE-5).
  has_many :pva_view_events
  has_many :pva_view_rollups
  has_many :pva_chat_activities
  has_many :pva_engagement_events
  has_many :channel_tenures
  has_many :pva_supporter_statuses
  has_many :pva_weekly_reflections
  has_many :pva_patterns
  has_one :pva_cohort
  has_one :user_privacy_setting

  VALID_LOCALES = %w[en ru].freeze

  validates :role, inclusion: { in: %w[viewer streamer] }
  validates :tier, inclusion: { in: %w[free premium business] }
  validates :locale, inclusion: { in: VALID_LOCALES }, allow_nil: true
  validates :avatar_url, format: { with: /\Ahttps?:\/\/\S+\z/i, message: "must be a valid URL" }, allow_blank: true

  scope :active, -> { where(deleted_at: nil) }

  # TASK-039 FR-039: Memoized Twitch IDs of channels broadcaster по active OAuth providers.
  # Eliminates per-policy-call N+1 (10 Trends endpoints на странице → 1 query вместо 10).
  # Single Twitch OAuth = single channel today; Set keeps API stable если modeling меняется.
  def streamer_twitch_ids
    @streamer_twitch_ids ||= auth_providers
                             .where(provider: "twitch")
                             .pluck(:provider_id)
                             .to_set
  end

  # T1-060 FR-3: accumulating role predicates. viewer = implicit for every registered
  # user; is_streamer / is_brand accumulate by action and may both be true. Distinct from
  # the channel-ownership axis (streamer_twitch_ids / owns_channel?), which is orthogonal.
  def viewer?
    true
  end

  def streamer?
    is_streamer
  end

  def brand?
    is_brand
  end

  def has_role?(role_name)
    public_send("#{role_name}?")
  end

  def roles
    [ :viewer, (:streamer if is_streamer), (:brand if is_brand) ].compact
  end
end
