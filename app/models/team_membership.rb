# frozen_string_literal: true

class TeamMembership < ApplicationRecord
  belongs_to :user
  belongs_to :team_owner, class_name: "User"

  validates :role, inclusion: { in: %w[member admin] }
  validates :status, inclusion: { in: %w[active removed] }
  validates :user_id, uniqueness: { scope: :team_owner_id }
end
