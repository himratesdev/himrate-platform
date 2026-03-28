# frozen_string_literal: true

class StreamerRating < ApplicationRecord
  belongs_to :channel

  validates :rating_score, presence: true, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 100 }
  validates :decay_lambda, presence: true, numericality: { greater_than: 0, less_than_or_equal_to: 1 }
  validates :streams_count, presence: true
  validates :calculated_at, presence: true
end
