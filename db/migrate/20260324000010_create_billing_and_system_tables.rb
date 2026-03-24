# frozen_string_literal: true

class CreateBillingAndSystemTables < ActiveRecord::Migration[8.0]
  def change
    create_table :score_disputes, id: :uuid do |t|
      t.references :user, type: :uuid, null: false, foreign_key: true
      t.references :channel, type: :uuid, null: false, foreign_key: true
      t.datetime :submitted_at, null: false
      t.text :reason, null: false
      t.string :resolution_status, limit: 20, null: false, default: "pending"
      t.datetime :resolution_at
    end

    create_table :pdf_reports, id: :uuid do |t|
      t.references :user, type: :uuid, null: false, foreign_key: true
      t.references :channel, type: :uuid, null: false, foreign_key: true
      t.string :report_type, limit: 20, null: false
      t.text :file_path
      t.boolean :is_white_label, null: false, default: false
      t.string :share_token, limit: 64

      t.timestamps
    end

    add_index :pdf_reports, :share_token, unique: true

    create_table :api_keys, id: :uuid do |t|
      t.references :user, type: :uuid, null: false, foreign_key: true
      t.string :key_hash, limit: 255, null: false
      t.string :name, limit: 255, null: false
      t.jsonb :scopes, default: []
      t.integer :rate_limit, null: false, default: 20
      t.boolean :is_active, null: false, default: true
      t.datetime :last_used_at

      t.timestamps
    end

    add_index :api_keys, :key_hash, unique: true

    create_table :sessions, id: :uuid do |t|
      t.references :user, type: :uuid, null: false, foreign_key: true
      t.string :token, limit: 255, null: false
      t.datetime :expires_at, null: false
      t.inet :ip_address
      t.text :user_agent
      t.boolean :is_active, null: false, default: true

      t.timestamps
    end

    add_index :sessions, :token, unique: true

    create_table :notifications, id: :uuid do |t|
      t.references :user, type: :uuid, null: false, foreign_key: true
      t.string :type, limit: 50, null: false
      t.references :channel, type: :uuid, foreign_key: true
      t.references :stream, type: :uuid, foreign_key: true
      t.datetime :sent_at
      t.datetime :read_at
      t.string :priority, limit: 10

      t.timestamps
    end
  end
end
