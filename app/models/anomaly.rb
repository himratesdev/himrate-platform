# frozen_string_literal: true

class Anomaly < ApplicationRecord
  # TASK-085 FR-019 (ADR-085 D-2): bot_wave → anomaly_wave (legal-safe per CLAUDE.md ERV v3).
  # TASK-085 FR-014 + FR-015: ti_drop + erv_divergence added для new detectors.
  ANOMALY_TYPES = %w[
    anomaly_wave viewbot_spike follow_bot raid_bot chat_bot organic_spike host_raid
    auth_ratio chatter_ccv_ratio ccv_step_function ccv_tier_clustering
    chat_behavior channel_protection_score cross_channel_presence
    known_bot_match raid_attribution ccv_chat_correlation account_profile_scoring
    compute_failure ti_drop erv_divergence
  ].freeze

  belongs_to :stream
  # SF-5 CR iter 2: delete_all vs destroy — attribution data без callbacks,
  # pipeline может создавать N attributions per anomaly, single SQL DELETE faster.
  has_many :anomaly_attributions, dependent: :delete_all

  validates :timestamp, presence: true
  validates :anomaly_type, presence: true, inclusion: { in: ANOMALY_TYPES }
end
