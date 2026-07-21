# frozen_string_literal: true

class User < ApplicationRecord
  include Flipper::Identifier
  has_many :auth_providers, dependent: :destroy
  has_many :subscriptions, dependent: :destroy
  has_many :tracked_channels, dependent: :destroy
  has_many :channels, through: :tracked_channels
  has_many :watchlists, dependent: :destroy
  has_many :recent_channels, dependent: :destroy
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

  # Email-marketing foundation: log a `registered` lifecycle event once per new user,
  # after commit (never rolls back the signup; fires for every provider). This is the
  # hook action-triggered campaigns build on.
  after_create_commit :record_registration_event

  # TASK-039 FR-039: Memoized Twitch IDs of channels broadcaster по active OAuth providers.
  # Eliminates per-policy-call N+1 (10 Trends endpoints на странице → 1 query вместо 10).
  # Single Twitch OAuth = single channel today; Set keeps API stable если modeling меняется.
  def streamer_twitch_ids
    @streamer_twitch_ids ||= auth_providers
                             .where(provider: "twitch")
                             .pluck(:provider_id)
                             .to_set
  end

  # T1-060 FR-3: accumulating role predicates. viewer = implicit for every registered user;
  # roles may be held simultaneously. Distinct from the channel-ownership axis
  # (streamer_twitch_ids / owns_channel?), which is orthogonal.
  #
  # is_streamer is STORED (captures an external Twitch broadcaster_type signal at OAuth);
  # brand is DERIVED at read-time from business access (our own internal tier + team data),
  # so it can never drift from the actual business status the way a stored flag would.
  def viewer?
    true
  end

  def streamer?
    is_streamer
  end

  # Mirrors ApplicationPolicy#effective_business? (business tier OR active business-team).
  def brand?
    tier == "business" || business_via_active_team?
  end

  ROLE_NAMES = %i[viewer streamer brand].freeze

  def has_role?(role_name)
    ROLE_NAMES.include?(role_name.to_s.to_sym) && public_send("#{role_name}?")
  end

  def roles
    [ :viewer, (:streamer if streamer?), (:brand if brand?) ].compact
  end

  def record_registration_event
    UserEvents::Recorder.record(self, UserEvent::REGISTERED, { email_source: email_source })
  rescue StandardError => e
    # A logging failure must never surface to the just-registered user.
    Rails.logger.error("[User#record_registration_event] #{id}: #{e.class} #{e.message}")
    Sentry.capture_exception(e) if defined?(Sentry)
  end

  def business_via_active_team?
    team_memberships.where(status: "active")
                    .joins("INNER JOIN users AS owners ON owners.id = team_memberships.team_owner_id")
                    .where(owners: { tier: "business" })
                    .exists?
  end
end
