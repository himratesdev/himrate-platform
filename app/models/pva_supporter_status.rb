# frozen_string_literal: true

# TASK-113 (FR-008, M9 «Моё место у каналов»): КАТЕГОРИАЛЬНЫЙ абсолютный статус сапортёра.
# НЕ числовой публичный скор (BR-006), НЕ percentile-vs-others. composite_score = internal-only
# (маппинг в tier; в UI не показывается). SupporterStatusWorker пересчитывает.
class PvaSupporterStatus < ApplicationRecord
  self.table_name = "pva_supporter_status"

  TIERS = %w[devoted loyal regular active].freeze

  belongs_to :user

  validates :user_id, presence: true
  # twitch_channel_id = стабильный ключ (BE-3 client-capture refine); channel_id(uuid) = nullable enrichment.
  validates :twitch_channel_id, presence: true, uniqueness: { scope: :user_id }
  validates :tier, presence: true, inclusion: { in: TIERS }
  validates :computed_at, presence: true

  scope :for_user, ->(user) { where(user_id: user.id) }
end
