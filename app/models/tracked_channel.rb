# frozen_string_literal: true

class TrackedChannel < ApplicationRecord
  belongs_to :user
  belongs_to :channel
  belongs_to :subscription, optional: true
end
