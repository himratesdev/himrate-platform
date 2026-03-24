# frozen_string_literal: true

class CreateAnalyticsTables < ActiveRecord::Migration[8.0]
  def change
    create_table :signals, id: :uuid do |t|
      t.references :stream, type: :uuid, null: false, foreign_key: true
      t.datetime :timestamp, null: false
      t.string :signal_type, limit: 50, null: false
      t.decimal :value, precision: 10, scale: 4, null: false
      t.decimal :confidence, precision: 5, scale: 4
      t.decimal :weight_in_ti, precision: 5, scale: 4
    end

    add_index :signals, :timestamp
    add_index :signals, :signal_type

    create_table :trust_index_history, id: :uuid do |t|
      t.references :channel, type: :uuid, null: false, foreign_key: true
      t.references :stream, type: :uuid, foreign_key: true
      t.decimal :trust_index_score, precision: 5, scale: 2, null: false
      t.decimal :confidence, precision: 5, scale: 4
      t.jsonb :signal_breakdown, default: {}
      t.datetime :calculated_at, null: false
    end

    add_index :trust_index_history, :calculated_at

    create_table :erv_estimates, id: :uuid do |t|
      t.references :stream, type: :uuid, null: false, foreign_key: true
      t.datetime :timestamp, null: false
      t.integer :erv_count, null: false
      t.decimal :erv_percent, precision: 5, scale: 2, null: false
      t.decimal :confidence, precision: 5, scale: 4
      t.string :label, limit: 30
    end

    create_table :per_user_bot_scores, id: :uuid do |t|
      t.string :username, limit: 255, null: false
      t.string :user_id, limit: 50
      t.references :stream, type: :uuid, null: false, foreign_key: true
      t.decimal :bot_score, precision: 5, scale: 4, null: false
      t.decimal :confidence, precision: 5, scale: 4
      t.jsonb :components, default: {}
    end

    add_index :per_user_bot_scores, :username

    create_table :health_scores, id: :uuid do |t|
      t.references :channel, type: :uuid, null: false, foreign_key: true
      t.references :stream, type: :uuid, foreign_key: true
      t.decimal :health_score, precision: 5, scale: 2, null: false
      t.decimal :ti_component, precision: 5, scale: 2
      t.decimal :stability_component, precision: 5, scale: 2
      t.decimal :engagement_component, precision: 5, scale: 2
      t.decimal :growth_component, precision: 5, scale: 2
      t.decimal :consistency_component, precision: 5, scale: 2
      t.string :confidence_level, limit: 20
      t.datetime :calculated_at, null: false
    end

    create_table :streamer_reputations, id: :uuid do |t|
      t.references :channel, type: :uuid, null: false, foreign_key: true
      t.decimal :growth_pattern_score, precision: 5, scale: 2
      t.decimal :follower_quality_score, precision: 5, scale: 2
      t.decimal :engagement_consistency_score, precision: 5, scale: 2
      t.datetime :calculated_at, null: false
    end

    add_index :streamer_reputations, :channel_id, unique: true

    create_table :post_stream_reports, id: :uuid do |t|
      t.references :stream, type: :uuid, null: false, foreign_key: true
      t.integer :erv_final
      t.decimal :erv_percent_final, precision: 5, scale: 2
      t.decimal :trust_index_final, precision: 5, scale: 2
      t.integer :ccv_peak
      t.integer :ccv_avg
      t.bigint :duration_ms
      t.jsonb :signals_summary, default: {}
      t.jsonb :anomalies, default: []
      t.datetime :generated_at, null: false
    end

    add_index :post_stream_reports, :stream_id, unique: true

    create_table :raid_attributions, id: :uuid do |t|
      t.references :stream, type: :uuid, null: false, foreign_key: true
      t.datetime :timestamp, null: false
      t.references :source_channel, type: :uuid, foreign_key: { to_table: :channels }
      t.integer :raid_viewers_count
      t.boolean :is_bot_raid, null: false, default: false
      t.decimal :bot_score, precision: 5, scale: 4
      t.jsonb :signal_scores, default: {}
    end

    create_table :anomalies, id: :uuid do |t|
      t.references :stream, type: :uuid, null: false, foreign_key: true
      t.datetime :timestamp, null: false
      t.string :anomaly_type, limit: 30, null: false
      t.string :cause, limit: 30
      t.decimal :confidence, precision: 5, scale: 4
      t.integer :ccv_impact
      t.jsonb :details, default: {}
    end
  end
end
