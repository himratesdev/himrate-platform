# frozen_string_literal: true

# TASK-113 (FR-008, M8 свёрнут в M9): точный sub-tenure по каналу (IRC badge-info, не capped).
class ChannelTenure < ApplicationRecord
  self.table_name = "channel_tenure"

  belongs_to :user

  validates :user_id, presence: true
  # twitch_channel_id = стабильный ключ (BE-3 client-capture refine); channel_id(uuid) = nullable enrichment.
  validates :twitch_channel_id, presence: true, uniqueness: { scope: :user_id }
  validates :months, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :streak, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :sub_tier, inclusion: { in: [ 1, 2, 3 ] }, allow_nil: true

  scope :for_user, ->(user) { where(user_id: user.id) }
end
