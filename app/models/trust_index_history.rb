# frozen_string_literal: true

class TrustIndexHistory < ApplicationRecord
  belongs_to :channel
  belongs_to :stream, optional: true
end
