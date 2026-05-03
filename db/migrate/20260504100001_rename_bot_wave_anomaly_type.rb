# frozen_string_literal: true

# TASK-085 FR-019 (ADR-085 D-2): rename legal-violation enum value bot_wave → anomaly_wave.
# Per CLAUDE.md ERV labels v3: legal-safe wording mandatory во ВСЕХ контекстах,
# включая internal enum + DB stored values + code comments + tests + fixtures.
#
# Order critical: this migration runs BEFORE Anomaly::ANOMALY_TYPES code reload.
# Kamal handles via auto db:migrate before container restart.
# update_all bypasses model validations — required because old anomalies
# pre-deploy contain 'bot_wave' which won't be in new ANOMALY_TYPES constant.
#
# Rollback caveat (CR N-3 acknowledgement): down restores 'bot_wave' values в DB.
# Code rollback (revert Anomaly::ANOMALY_TYPES constant) MUST happen в одной atomic
# operation с migration:down — иначе model validation rejects existing rows.
# Kamal handles atomic rollback (revert PR + redeploy с previous tag OR `kamal rollback`).
# Manual rollback runbook: (1) git revert PR-1, (2) deploy reverted code, (3) rake db:rollback STEP=4.

class RenameBotWaveAnomalyType < ActiveRecord::Migration[8.0]
  def up
    Anomaly.where(anomaly_type: "bot_wave").update_all(anomaly_type: "anomaly_wave")
  end

  def down
    Anomaly.where(anomaly_type: "anomaly_wave").update_all(anomaly_type: "bot_wave")
  end
end
