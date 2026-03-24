# frozen_string_literal: true

class CreateUserDataTables < ActiveRecord::Migration[8.0]
  def change
    create_table :user_accounts, id: :uuid do |t|
      t.string :username, limit: 255, null: false
      t.string :twitch_id, limit: 50
      t.datetime :created_at
      t.integer :followers_total
      t.integer :follows_total
      t.boolean :is_partner, null: false, default: false
      t.boolean :is_affiliate, null: false, default: false
      t.datetime :last_updated_at
    end

    add_index :user_accounts, :username, unique: true
    add_index :user_accounts, :twitch_id, unique: true

    create_table :known_bot_list, id: :uuid do |t|
      t.string :username, limit: 255, null: false
      t.string :source, limit: 30, null: false
      t.decimal :confidence, precision: 5, scale: 4, null: false
      t.boolean :verified, null: false, default: false
      t.datetime :added_at, null: false
    end

    add_index :known_bot_list, :username, unique: true

    create_table :channel_protection_configs, id: :uuid do |t|
      t.references :channel, type: :uuid, null: false, foreign_key: true
      t.integer :followers_only_duration_min
      t.integer :slow_mode_seconds
      t.boolean :emote_only_enabled, null: false, default: false
      t.boolean :subs_only_enabled, null: false, default: false
      t.boolean :email_verification_required, null: false, default: false
      t.boolean :phone_verification_required, null: false, default: false
      t.decimal :channel_protection_score, precision: 5, scale: 2
      t.datetime :last_checked_at
    end

    add_index :channel_protection_configs, :channel_id, unique: true

    create_table :watchlists, id: :uuid do |t|
      t.references :user, type: :uuid, null: false, foreign_key: true
      t.string :name, limit: 255, null: false
      t.jsonb :channels_list, null: false, default: []

      t.timestamps
    end

    create_table :watchlist_tags_notes, id: :uuid do |t|
      t.references :watchlist, type: :uuid, null: false, foreign_key: true
      t.references :channel, type: :uuid, null: false, foreign_key: true
      t.jsonb :tags, default: []
      t.text :notes
      t.datetime :added_at, null: false
    end
  end
end
