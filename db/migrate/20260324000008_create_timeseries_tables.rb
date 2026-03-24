# frozen_string_literal: true

class CreateTimeseriesTables < ActiveRecord::Migration[8.0]
  def change
    create_table :ccv_snapshots, id: :uuid do |t|
      t.references :stream, type: :uuid, null: false, foreign_key: true
      t.datetime :timestamp, null: false
      t.integer :ccv_count, null: false
      t.integer :real_viewers_estimate
      t.decimal :confidence, precision: 5, scale: 4
    end

    add_index :ccv_snapshots, :timestamp

    create_table :chatters_snapshots, id: :uuid do |t|
      t.references :stream, type: :uuid, null: false, foreign_key: true
      t.datetime :timestamp, null: false
      t.integer :unique_chatters_count, null: false
      t.integer :total_messages_count, null: false
      t.decimal :auth_ratio, precision: 5, scale: 4
    end

    create_table :chat_messages, id: :uuid do |t|
      t.references :stream, type: :uuid, null: false, foreign_key: true
      t.string :username, limit: 255, null: false
      t.text :message_text
      t.datetime :timestamp, null: false
      t.string :subscriber_status, limit: 10
      t.boolean :is_first_msg, null: false, default: false
      t.string :user_type, limit: 10
      t.integer :bits_used, default: 0
      t.decimal :entropy, precision: 8, scale: 4
    end

    add_index :chat_messages, :username
    add_index :chat_messages, :timestamp
  end
end
