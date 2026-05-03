# frozen_string_literal: true

# TASK-085 FR-019 (ADR-085 D-2): rename legal-violation enum value bot_wave → anomaly_wave.
# Per CLAUDE.md ERV labels v3: legal-safe wording mandatory во ВСЕХ контекстах,
# включая internal enum + DB stored values + code comments + tests + fixtures.
#
# Order critical: this migration runs BEFORE Anomaly::ANOMALY_TYPES code reload.
# Kamal handles via auto db:migrate before container restart.
# update_all bypasses model validations — required because old anomalies
# pre-deploy contain 'bot_wave' which won't be in new ANOMALY_TYPES constant.

class RenameBotWaveAnomalyType < ActiveRecord::Migration[8.0]
  def up
    Anomaly.where(anomaly_type: "bot_wave").update_all(anomaly_type: "anomaly_wave")
  end

  def down
    Anomaly.where(anomaly_type: "anomaly_wave").update_all(anomaly_type: "bot_wave")
  end
end
