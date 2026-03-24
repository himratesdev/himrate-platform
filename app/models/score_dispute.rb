# frozen_string_literal: true

class ScoreDispute < ApplicationRecord
  belongs_to :user
  belongs_to :channel
end
