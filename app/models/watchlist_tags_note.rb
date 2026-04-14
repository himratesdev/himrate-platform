# frozen_string_literal: true

# TASK-036 FR-009: Tags and notes per channel per watchlist.
class WatchlistTagsNote < ApplicationRecord
  belongs_to :watchlist
  belongs_to :channel

  validates :channel_id, uniqueness: { scope: :watchlist_id }
  validates :notes, length: { maximum: 500 }, allow_nil: true

  validate :tags_limit

  private

  def tags_limit
    errors.add(:tags, "cannot exceed 20") if tags.is_a?(Array) && tags.size > 20
  end
end
