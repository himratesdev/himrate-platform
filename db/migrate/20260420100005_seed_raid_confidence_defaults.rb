# frozen_string_literal: true

# TASK-039 Phase B1b PG O-1: extract hardcoded Raid confidence constants в
# SignalConfiguration (consistency с platform_cleanup thresholds approach).
#
# - raid_organic_default_confidence=0.8 — organic raids не имеют bot_score,
#   this confidence reflects matching certainty (raid occurred → anomaly likely explained).
# - raid_bot_fallback_confidence=0.8 — fallback когда RaidAttribution.bot_score = NULL
#   (legacy data или failure of bot_detection). Admin may adjust if accuracy issues.

class SeedRaidConfidenceDefaults < ActiveRecord::Migration[8.0]
  SEEDS = [
    { param_name: "raid_organic_default_confidence", param_value: 0.8 },
    { param_name: "raid_bot_fallback_confidence", param_value: 0.8 }
  ].freeze

  def up
    now = Time.current
    rows = SEEDS.map do |seed|
      {
        signal_type: "trust_index",
        category: "raid_attribution",
        param_name: seed[:param_name],
        param_value: seed[:param_value],
        created_at: now,
        updated_at: now
      }
    end

    SignalConfiguration.upsert_all(rows, unique_by: %i[signal_type category param_name])
  end

  def down
    SignalConfiguration.where(
      signal_type: "trust_index",
      category: "raid_attribution"
    ).delete_all
  end
end
