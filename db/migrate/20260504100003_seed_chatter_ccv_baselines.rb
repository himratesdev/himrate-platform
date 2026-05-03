# frozen_string_literal: true

# TASK-085 FR-022 (ADR-085 D-1): seed category-specific auth baselines per BFT 08.4
# для chatter_to_ccv_anomaly severity computation.
#
# Storage strategy: extend existing signal_configurations table (TASK-028 pattern)
# instead of new anomaly_baselines table — leverages SignalConfiguration.value_for
# request-scoped memoization (Current.signal_config) + automatic 'default' fallback.
#
# 12 rows: 5 game categories + 'default' fallback × 2 params (baseline_min, baseline_max).
# Music/ASMR shares 'Music' category — presenter normalizes 'ASMR' → 'Music' on lookup.
#
# Idempotent via find_or_create_by! — multi-deploy safe.

class SeedChatterCcvBaselines < ActiveRecord::Migration[8.0]
  BASELINES = {
    "Just Chatting" => { min: 75, max: 90 },
    "IRL"           => { min: 75, max: 90 },
    "Gaming"        => { min: 65, max: 80 },
    "Esports"       => { min: 30, max: 60 },
    "Music"         => { min: 40, max: 70 },
    "default"       => { min: 65, max: 80 }
  }.freeze

  def up
    BASELINES.each do |category, range|
      %i[min max].each do |bound|
        param_name = "baseline_#{bound}"
        config = SignalConfiguration.find_or_initialize_by(
          signal_type: "chatter_ccv_ratio",
          category: category,
          param_name: param_name
        )
        config.param_value = range[bound]
        config.save!
      end
    end
  end

  def down
    SignalConfiguration.where(
      signal_type: "chatter_ccv_ratio",
      param_name: %w[baseline_min baseline_max]
    ).delete_all
  end
end
