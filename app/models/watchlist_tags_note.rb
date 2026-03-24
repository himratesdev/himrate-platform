# frozen_string_literal: true

class WatchlistTagsNote < ApplicationRecord
  belongs_to :watchlist
  belongs_to :channel
end
