# frozen_string_literal: true

class AddPatternHistoryScoreToStreamerReputations < ActiveRecord::Migration[8.0]
  def change
    add_column :streamer_reputations, :pattern_history_score, :decimal, precision: 5, scale: 2
  end
end
