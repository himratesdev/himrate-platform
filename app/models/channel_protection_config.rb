# frozen_string_literal: true

# TASK-025: Enhanced with validations.

class ChannelProtectionConfig < ApplicationRecord
  belongs_to :channel

  validates :channel_id, uniqueness: true
end
