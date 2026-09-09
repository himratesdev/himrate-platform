# frozen_string_literal: true

# One channel↔channel tie inside a ring: how many accounts of the shared pool co-fired in BOTH
# channels, and how many bursts they carry. Renders the group's matrix.
class CoordinationEdge < ApplicationRecord
  belongs_to :coordination_group

  validates :a_login, :b_login, presence: true
end
