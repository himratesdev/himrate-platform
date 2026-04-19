# frozen_string_literal: true

class Anomaly < ApplicationRecord
  ANOMALY_TYPES = %w[
    bot_wave viewbot_spike follow_bot raid_bot chat_bot organic_spike host_raid
    auth_ratio chatter_ccv_ratio ccv_step_function ccv_tier_clustering
    chat_behavior channel_protection_score cross_channel_presence
    known_bot_match raid_attribution ccv_chat_correlation account_profile_scoring
    compute_failure
  ].freeze

  belongs_to :stream
  # SF-5 CR iter 2: delete_all vs destroy — attribution data без callbacks,
  # pipeline может создавать N attributions per anomaly, single SQL DELETE faster.
  has_many :anomaly_attributions, dependent: :delete_all

  validates :timestamp, presence: true
  validates :anomaly_type, presence: true, inclusion: { in: ANOMALY_TYPES }
end
