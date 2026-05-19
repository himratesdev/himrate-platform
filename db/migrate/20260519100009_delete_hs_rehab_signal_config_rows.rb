# frozen_string_literal: true

# TASK-201 Phase 3.1: delete HS / Rehab / Recommendation rows из signal_configurations.
# 3 sub-scopes mirror original seed migrations:
#   1. signal_type='health_score' — 105 rows (21 categories × 5 weight params),
#      seeded by 20260417100009_seed_health_score_category_weights.rb
#   2. signal_type='recommendation' — 4 rows (TI drop thresholds),
#      seeded by 20260417100010_seed_recommendation_config.rb
#   3. signal_type='trust_index' AND category='rehabilitation' — 1 row
#      (clean_stream_ti_threshold), seeded by 20260420100002_seed_clean_stream_ti_threshold.rb
#
# NB: ADR-201 §4.1 originally specified `WHERE category IN ('health_score', 'rehabilitation')`.
# Verified против actual seed migrations — sub-scopes are signal_type-keyed, not category-keyed.
# Scope unchanged (всё ещё «remove HS/Rehab SignalConfig rows»), only the SQL precision corrected.
#
# Live signal_type='trust_index' rows (live signals, cold-start thresholds etc.) preserved.

class DeleteHsRehabSignalConfigRows < ActiveRecord::Migration[8.0]
  def up
    SignalConfiguration.where(signal_type: "health_score").delete_all
    SignalConfiguration.where(signal_type: "recommendation").delete_all
    SignalConfiguration
      .where(signal_type: "trust_index", category: "rehabilitation")
      .delete_all
  end

  def down
    now = Time.current

    # Re-seed health_score rows (verbatim from 20260417100009).
    weights_matrix = [
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
    ]
    health_score_rows = []
    weights_matrix.each do |key, ti, stability, engagement, growth, consistency|
      { ti: ti, stability: stability, engagement: engagement, growth: growth, consistency: consistency }.each do |param, value|
        health_score_rows << {
          signal_type: "health_score",
          category: key,
          param_name: "weight_#{param}",
          param_value: value,
          created_at: now,
          updated_at: now
        }
      end
    end
    SignalConfiguration.upsert_all(health_score_rows, unique_by: %i[signal_type category param_name])

    # Re-seed recommendation rows (verbatim from 20260417100010).
    recommendation_rows = [
      { signal_type: "recommendation", category: "default", param_name: "ti_drop_window_days",
        param_value: 7, created_at: now, updated_at: now },
      { signal_type: "recommendation", category: "default", param_name: "ti_drop_threshold_pts",
        param_value: 15, created_at: now, updated_at: now },
      { signal_type: "recommendation", category: "default", param_name: "rehab_required_clean_streams",
        param_value: 15, created_at: now, updated_at: now },
      { signal_type: "recommendation", category: "default", param_name: "max_recommendations",
        param_value: 5, created_at: now, updated_at: now }
    ]
    SignalConfiguration.upsert_all(recommendation_rows, unique_by: %i[signal_type category param_name])

    # Re-seed clean_stream_ti_threshold (verbatim from 20260420100002).
    SignalConfiguration.find_or_create_by!(
      signal_type: "trust_index",
      category: "rehabilitation",
      param_name: "clean_stream_ti_threshold"
    ) { |c| c.param_value = 50 }
  end
end
