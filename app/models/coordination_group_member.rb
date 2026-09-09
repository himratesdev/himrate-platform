# frozen_string_literal: true

# A channel inside a ring. `channel_id` is optional on purpose: rings routinely reach channels we
# do not track, and dropping those would hide part of the evidence — `channel_login` is the identity.
class CoordinationGroupMember < ApplicationRecord
  belongs_to :coordination_group
  belongs_to :channel, optional: true

  validates :channel_login, presence: true
end
