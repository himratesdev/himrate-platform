# frozen_string_literal: true

class CreateUsers < ActiveRecord::Migration[8.0]
  def change
    create_table :users, id: :uuid do |t|
      t.string :email, limit: 255
      t.string :username, limit: 255
      t.string :role, limit: 20, null: false, default: "viewer"
      t.string :tier, limit: 20, null: false, default: "free"
      t.string :goal_tag, limit: 20
      t.datetime :deleted_at

      t.timestamps
    end

    add_index :users, :email, unique: true
    add_index :users, :username, unique: true
    add_index :users, :deleted_at
  end
end
