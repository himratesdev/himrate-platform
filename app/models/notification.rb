# frozen_string_literal: true

class Notification < ApplicationRecord
  self.inheritance_column = nil

  belongs_to :user
  belongs_to :channel, optional: true
  belongs_to :stream, optional: true
end
