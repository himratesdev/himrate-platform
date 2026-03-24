# frozen_string_literal: true

class ChatMessage < ApplicationRecord
  belongs_to :stream
end
