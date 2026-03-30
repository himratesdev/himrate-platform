# frozen_string_literal: true

# TASK-031: Add display_name, avatar_url, locale to users table.
# Required for GET /user/me and PATCH /user/me API endpoints.

class AddProfileFieldsToUsers < ActiveRecord::Migration[8.0]
  def up
    add_column :users, :display_name, :string, limit: 255
    add_column :users, :avatar_url, :text
    add_column :users, :locale, :string, limit: 5, default: "en", null: false
  end

  def down
    remove_column :users, :locale
    remove_column :users, :avatar_url
    remove_column :users, :display_name
  end
end
