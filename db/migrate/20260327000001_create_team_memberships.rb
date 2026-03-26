# frozen_string_literal: true

class CreateTeamMemberships < ActiveRecord::Migration[8.1]
  def change
    create_table :team_memberships, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :user, null: false, foreign_key: true, type: :uuid
      t.references :team_owner, null: false, foreign_key: { to_table: :users }, type: :uuid
      t.string :role, null: false, default: "member"
      t.string :status, null: false, default: "active"

      t.timestamps
    end

    add_index :team_memberships, %i[user_id team_owner_id], unique: true, name: "idx_team_memberships_user_owner"
    add_index :team_memberships, :team_owner_id, name: "idx_team_memberships_owner_id"
  end
end
