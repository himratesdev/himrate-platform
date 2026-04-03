# frozen_string_literal: true

# TASK-034 FR-025: Tracking requests for untracked channels.
# channel_login (VARCHAR) instead of FK — channel may not exist in DB yet.
class CreateTrackingRequests < ActiveRecord::Migration[8.1]
  def change
    create_table :tracking_requests, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.string :channel_login, null: false, limit: 50
      t.uuid :user_id
      t.uuid :extension_install_id
      t.string :status, null: false, default: "pending", limit: 20

      t.timestamps
    end

    add_index :tracking_requests, :channel_login
    add_index :tracking_requests, [ :channel_login, :user_id ],
      unique: true,
      where: "user_id IS NOT NULL",
      name: "idx_tracking_requests_unique_user"
    add_index :tracking_requests, [ :channel_login, :extension_install_id ],
      unique: true,
      where: "extension_install_id IS NOT NULL",
      name: "idx_tracking_requests_unique_guest"
    add_foreign_key :tracking_requests, :users, column: :user_id, on_delete: :nullify
  end

  def down
    drop_table :tracking_requests
  end
end
