# frozen_string_literal: true

# BUG-010 PR2: accessory state — current vs previous image для rollback target tracking.
# AccessoryOps::StateService manages CRUD. AccessoryOps::StateCacheService mirrors к file
# (DB-down fallback per FR-125/126).

class AccessoryState < ApplicationRecord
  validates :destination, :accessory, :current_image, presence: true
  validates :destination, uniqueness: { scope: :accessory }

  def rollback_available?
    previous_image.present? && previous_image != current_image
  end
end
