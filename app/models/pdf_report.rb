# frozen_string_literal: true

class PdfReport < ApplicationRecord
  belongs_to :user
  belongs_to :channel
end
