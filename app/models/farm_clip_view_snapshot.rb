# frozen_string_literal: true

# EPIC FARM: point-in-time view_count of one farm clip (velocity = d(views)/dt).
class FarmClipViewSnapshot < ApplicationRecord
  belongs_to :farm_clip

  validates :view_count, :captured_at, presence: true
end
