# frozen_string_literal: true

# TASK-029: ERV estimate per stream snapshot.

class ErvEstimate < ApplicationRecord
  belongs_to :stream

  validates :timestamp, presence: true
  validates :erv_count, presence: true
  validates :erv_percent, presence: true
end
