# frozen_string_literal: true

# TASK-085 FR-022 (ADR-085 D-1) + PG W-2: chatter_ccv_ratio category baselines.
# Moved out of migration 20260504100003 per ai-dev-team/CLAUDE.md
# "Миграции — Нет данных в миграциях".
#
# Storage strategy: extends existing signal_configurations table (TASK-028 pattern)
# instead of new anomaly_baselines table — leverages SignalConfiguration.value_for
# request-scoped memoization (Current.signal_config) + automatic 'default' fallback.
#
# 12 rows: 5 game categories + 'default' fallback × 2 params (baseline_min, baseline_max).
# Music/ASMR shares 'Music' category — Trust::AnomalyAlertsPresenter normalizes
# 'ASMR' → 'Music' on lookup.
#
# Idempotent via find_or_initialize_by + save! — multi-deploy safe.
# Auto-loaded from db/seeds.rb on every `rails db:seed` (after migrate per
# deployment_verification.md checklist).

module ChatterCcvBaselines
  BASELINES = {
    "Just Chatting" => { min: 75, max: 90 },
    "IRL"           => { min: 75, max: 90 },
    "Gaming"        => { min: 65, max: 80 },
    "Esports"       => { min: 30, max: 60 },
    "Music"         => { min: 40, max: 70 },
    "default"       => { min: 65, max: 80 }
  }.freeze

  def self.run
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
end

ChatterCcvBaselines.run if defined?(SignalConfiguration)
