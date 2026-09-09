# frozen_string_literal: true

# One detected ring: a set of channels tied together by a shared pool of accounts that post in
# three or more of them inside the same 5-second window. Written wholesale by Coordination::Snapshot.
#
# `corroborated` is the gate on wording. Only a group whose account pool intersects
# `named_bot_evidences` (the TI engine's own hard per-account verdict) may be presented with the
# accusatory headline on the channel card; everything else states the observation and its numbers
# and lets the reader draw the conclusion. See WEB-CONSOLIDATION DESIGN-BRIEF §7 block 0.
class CoordinationGroup < ApplicationRecord
  has_many :members, class_name: "CoordinationGroupMember", dependent: :delete_all
  has_many :edges, class_name: "CoordinationEdge", dependent: :delete_all
  has_many :accounts, class_name: "CoordinationAccount", dependent: :delete_all

  validates :member_count, :accounts_shared, :events, :window_days, presence: true
  validates :first_seen_at, :computed_at, presence: true

  scope :fresh, ->(within: 6.hours) { where(computed_at: within.ago..) }

  # Groups a channel belongs to, freshest first. The card's only query.
  def self.for_channel_login(login)
    joins(:members).where(coordination_group_members: { channel_login: login.to_s.downcase })
                   .order(computed_at: :desc)
  end

  def member_logins
    members.order(ties: :desc).pluck(:channel_login)
  end
end
