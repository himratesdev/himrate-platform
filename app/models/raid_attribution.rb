# frozen_string_literal: true

class RaidAttribution < ApplicationRecord
  belongs_to :stream
  belongs_to :source_channel, class_name: "Channel", optional: true
end
