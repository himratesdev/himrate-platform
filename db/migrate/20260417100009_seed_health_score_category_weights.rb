# frozen_string_literal: true

# TASK-038 FR-013: Seed 20 top Twitch categories + default weights into SignalConfiguration.
# Weights per BFT §9. Categories per Twitch Top 20 2025. Post-launch calibration via UPDATE.

class SeedHealthScoreCategoryWeights < ActiveRecord::Migration[8.0]
  WEIGHTS_MATRIX = [
    # key, ti, stability, engagement, growth, consistency
    [ "just_chatting", 0.30, 0.15, 0.30, 0.10, 0.15 ],
    [ "league_of_legends", 0.30, 0.20, 0.20, 0.15, 0.15 ],
    [ "grand_theft_auto_v", 0.30, 0.20, 0.20, 0.15, 0.15 ],
    [ "valorant", 0.35, 0.20, 0.10, 0.20, 0.15 ],
    [ "counter_strike_2", 0.35, 0.20, 0.10, 0.20, 0.15 ],
    [ "fortnite", 0.30, 0.20, 0.20, 0.15, 0.15 ],
    [ "minecraft", 0.30, 0.20, 0.20, 0.15, 0.15 ],
    [ "dota_2", 0.35, 0.20, 0.10, 0.20, 0.15 ],
    [ "world_of_warcraft", 0.30, 0.20, 0.20, 0.15, 0.15 ],
    [ "apex_legends", 0.30, 0.20, 0.20, 0.15, 0.15 ],
    [ "call_of_duty_warzone", 0.30, 0.20, 0.20, 0.15, 0.15 ],
    [ "overwatch_2", 0.30, 0.20, 0.20, 0.15, 0.15 ],
    [ "ea_sports_fc_25", 0.35, 0.20, 0.10, 0.20, 0.15 ],
    [ "rocket_league", 0.30, 0.20, 0.20, 0.15, 0.15 ],
    [ "music", 0.30, 0.25, 0.15, 0.10, 0.20 ],
    [ "asmr", 0.30, 0.25, 0.15, 0.10, 0.20 ],
    [ "art", 0.25, 0.20, 0.25, 0.10, 0.20 ],
    [ "irl", 0.30, 0.15, 0.30, 0.10, 0.15 ],
    [ "chess", 0.30, 0.20, 0.20, 0.15, 0.15 ],
    [ "slots", 0.30, 0.20, 0.20, 0.15, 0.15 ],
    [ "default", 0.30, 0.20, 0.20, 0.15, 0.15 ]
  ].freeze

  def up
    now = Time.current
    rows = []
    WEIGHTS_MATRIX.each do |key, ti, stability, engagement, growth, consistency|
      { ti: ti, stability: stability, engagement: engagement, growth: growth, consistency: consistency }.each do |param, value|
        rows << {
          signal_type: "health_score",
          category: key,
          param_name: "weight_#{param}",
          param_value: value,
          created_at: now,
          updated_at: now
        }
      end
    end

    SignalConfiguration.upsert_all(rows, unique_by: %i[signal_type category param_name])
  end

  def down
    SignalConfiguration.where(signal_type: "health_score").delete_all
  end
end
