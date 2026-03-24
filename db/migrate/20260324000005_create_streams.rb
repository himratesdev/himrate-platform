# frozen_string_literal: true

class CreateStreams < ActiveRecord::Migration[8.0]
  def change
    create_table :streams, id: :uuid do |t|
      t.references :channel, type: :uuid, null: false, foreign_key: true
      t.datetime :started_at, null: false
      t.datetime :ended_at
      t.bigint :duration_ms
      t.integer :peak_ccv, default: 0
      t.integer :avg_ccv, default: 0
      t.text :title
      t.string :game_name, limit: 255
      t.string :language, limit: 10
      t.boolean :is_mature, null: false, default: false
      t.string :merge_status, limit: 20, default: "separate"

      t.timestamps
    end

    add_index :streams, :started_at
  end
end
