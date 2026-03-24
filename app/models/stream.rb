# frozen_string_literal: true

class Stream < ApplicationRecord
  belongs_to :channel

  has_many :signals, class_name: "TiSignal", foreign_key: "stream_id", dependent: :destroy
  has_many :ccv_snapshots, dependent: :destroy
  has_many :chatters_snapshots, dependent: :destroy
  has_many :chat_messages, dependent: :destroy
  has_many :erv_estimates, dependent: :destroy
  has_many :per_user_bot_scores, dependent: :destroy
  has_many :trust_index_histories, dependent: :destroy
  has_many :health_scores, dependent: :destroy
  has_many :raid_attributions, dependent: :destroy
  has_many :anomalies, dependent: :destroy
  has_one :post_stream_report, dependent: :destroy

  validates :started_at, presence: true
end
