# frozen_string_literal: true

class CreateAuthProviders < ActiveRecord::Migration[8.0]
  def change
    create_table :auth_providers, id: :uuid do |t|
      t.references :user, type: :uuid, null: false, foreign_key: true
      t.string :provider, limit: 20, null: false
      t.string :provider_id, limit: 255, null: false
      t.text :access_token
      t.text :refresh_token
      t.datetime :expires_at
      t.jsonb :scopes, default: []
      t.boolean :is_broadcaster, null: false, default: false

      t.timestamps
    end

    add_index :auth_providers, [:provider, :provider_id], unique: true
  end
end
