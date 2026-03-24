# frozen_string_literal: true

class Watchlist < ApplicationRecord
  belongs_to :user
  has_many :watchlist_tags_notes, dependent: :destroy
end
