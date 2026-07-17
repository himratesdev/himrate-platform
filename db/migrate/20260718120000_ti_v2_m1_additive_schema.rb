# frozen_string_literal: true

# T1-074 (TI v2) — M1 additive schema. ADR DEC-4 step 1-2 / DEC-7 (ADD to trust_index_histories,
# not a sibling table) / SRS §5.1, §5.3.
#
# Adds the v2 engine outputs to trust_index_histories (the settled ADD decision — the MV needs
# DROP/CREATE in the sibling option too, so the sibling's clean-drop advantage is illusory; ADD
# avoids a join on every API read), makes trust_index_score NULLABLE (v2 rows carry no TI-scalar —
# fraud is `ERV = V − F̂`, not `TI = 100 − bot_score`), and creates the 3 v2 tables:
# calibration_constants + calibration_cell_baselines (configurable ρ*/φ/τ/LLR — illustrative until
# GATE 0) and named_bot_evidence (immutable dispute-safe P5 evidence — SRS §5.1, EC-13).
#
# ADDITIVE + REVERSIBLE only. The MV `latest_tih_per_stream` recreate + legacy-column DROP =
# M2 follow-up TASK after confirmed cutover (ADR DEC-4 step 7) — NOT here.
# engine_version defaults 'v1' (fail-safe: existing + legacy rows read as v1 with no code change;
# the v2 engine writes 'v2' explicitly — safer than a 'v2' default that a forgotten write corrupts,
# ADR MF-4). All v2 columns nullable (v1 rows leave them null; v2 rows leave TI-scalar null).

class TiV2M1AdditiveSchema < ActiveRecord::Migration[8.0]
  disable_ddl_transaction!

  def up
    # ── trust_index_histories: engine discriminator + make retired scalar nullable ──
    add_column :trust_index_histories, :engine_version, :string, limit: 8, null: false, default: "v1", if_not_exists: true
    change_column_null :trust_index_histories, :trust_index_score, true # v2 rows carry no TI-scalar

    # ── L1/L2/L3 fraud counts + intervals (decimal — viewer-count scale, 2dp) ──
    %i[f_hard f_hard_lo f_hard_hi f_soft f_soft_lo f_soft_hi f_hat f_hat_lo f_hat_hi f_self].each do |col|
      add_column :trust_index_histories, col, :decimal, precision: 12, scale: 2, if_not_exists: true
    end

    # ── L2/L3 intermediates (ratios/posteriors — 6dp) ──
    %i[eihc rho_obs rho_self rho_self_lo n_frac q_score a_hat].each do |col|
      add_column :trust_index_histories, col, :decimal, precision: 10, scale: 6, if_not_exists: true
    end
    add_column :trust_index_histories, :inflation_event, :boolean, null: false, default: false, if_not_exists: true

    # ── L4 emit: ERV count + interval, 3 axes, band, reason codes, plashka, cold-start ──
    add_column :trust_index_histories, :erv, :decimal, precision: 12, scale: 2, if_not_exists: true       # V − F̂ (count)
    add_column :trust_index_histories, :erv_lo, :decimal, precision: 12, scale: 2, if_not_exists: true
    add_column :trust_index_histories, :erv_hi, :decimal, precision: 12, scale: 2, if_not_exists: true
    add_column :trust_index_histories, :authenticity, :decimal, precision: 5, scale: 2, if_not_exists: true # axis 1: A = 100·(1−F̂/V)
    add_column :trust_index_histories, :reputation_band, :string, limit: 16, if_not_exists: true            # axis 2 (categorical)
    add_column :trust_index_histories, :engagement_context, :jsonb, if_not_exists: true                     # axis 3 (chat ratio, CPS)
    add_column :trust_index_histories, :band_row, :integer, if_not_exists: true                             # 1-6 (§D table)
    add_column :trust_index_histories, :band_color, :string, limit: 8, if_not_exists: true                  # red/yellow/amber/green/grey
    add_column :trust_index_histories, :band_label, :string, limit: 64, if_not_exists: true
    add_column :trust_index_histories, :reason_codes, :jsonb, if_not_exists: true                           # array of codes
    add_column :trust_index_histories, :confirmed_anomaly, :jsonb, if_not_exists: true                      # {shown, provenance}
    add_column :trust_index_histories, :cold_start_tier, :string, limit: 12, if_not_exists: true            # insufficient/basic/full
    add_column :trust_index_histories, :confidence_marker, :string, limit: 16, if_not_exists: true
    add_column :trust_index_histories, :calibrated, :boolean, null: false, default: false, if_not_exists: true # false until GATE 0

    # partial index for the shadow/dual-run split (only v2 rows queried during compare)
    add_index :trust_index_histories, %i[channel_id engine_version],
      name: "idx_tih_channel_engine_version", algorithm: :concurrently, if_not_exists: true

    # ── calibration_constants: configurable φ/τ/LLR (illustrative until GATE 0) ──
    create_table :calibration_constants, id: :uuid, if_not_exists: true do |t|
      t.string :param_name, null: false                 # e.g. phi_yellow, phi_red, tau_hard, llr_temporal_r7
      t.string :category, null: false, default: "default"
      t.decimal :param_value, precision: 12, scale: 6, null: false
      t.boolean :calibrated, null: false, default: false # false = illustrative (pre-GATE 0)
      t.text :notes
      t.timestamps
    end
    add_index :calibration_constants, %i[param_name category], unique: true,
      name: "idx_calibration_constants_param_category", if_not_exists: true

    # ── calibration_cell_baselines: per-cell ρ* (category × V-bucket × chat-mode × language) ──
    create_table :calibration_cell_baselines, id: :uuid, if_not_exists: true do |t|
      t.string :category, null: false                   # just_chatting / gaming / esports / irl / music / default
      t.string :v_bucket, null: false                   # e.g. 0-100 / 100-1k / 1k-5k / 5k+
      t.string :chat_mode, null: false, default: "open" # open / sub-only / followers-only / slow / emote-only
      t.string :language, null: false, default: "ru"
      t.decimal :rho_star, precision: 10, scale: 6, null: false # median honest chat/CCV ratio
      t.decimal :rho_lo, precision: 10, scale: 6, null: false   # P5-10 (gates label, honest≈0)
      t.decimal :rho_hi, precision: 10, scale: 6, null: false   # high percentile (interval)
      t.integer :sample_size, null: false, default: 0
      t.boolean :calibrated, null: false, default: false
      t.timestamps
    end
    add_index :calibration_cell_baselines, %i[category v_bucket chat_mode language], unique: true,
      name: "idx_calibration_cell_baselines_key", if_not_exists: true

    # ── named_bot_evidence: immutable dispute-safe P5 evidence (SRS §5.1, EC-13, DEC-9) ──
    # Written only on C_hard=true; reproducible on a 40-day dispute (raw may rotate / GATE 0 may
    # recalibrate τ_hard). Retention = dispute window (FK score_dispute_id, N-3).
    create_table :named_bot_evidences, id: :uuid, if_not_exists: true do |t|
      t.references :stream, type: :uuid, null: false, foreign_key: true, index: false
      t.string :username, null: false
      t.decimal :p_u, precision: 5, scale: 4, null: false       # per-identity bot posterior at flag time
      t.string :evidence_reason, null: false                    # HARD_NAMED_FRACTION driver
      t.references :score_dispute, type: :uuid, foreign_key: true, index: false # dispute-grace retention
      t.datetime :calculated_at, null: false
    end
    add_index :named_bot_evidences, %i[stream_id username], unique: true,
      name: "idx_named_bot_evidence_stream_user", algorithm: :concurrently, if_not_exists: true
  end

  def down
    drop_table :named_bot_evidences, if_exists: true
    drop_table :calibration_cell_baselines, if_exists: true
    drop_table :calibration_constants, if_exists: true

    remove_index :trust_index_histories, name: "idx_tih_channel_engine_version", if_exists: true
    %i[
      engine_version f_hard f_hard_lo f_hard_hi f_soft f_soft_lo f_soft_hi f_hat f_hat_lo f_hat_hi
      f_self eihc rho_obs rho_self rho_self_lo n_frac q_score a_hat inflation_event
      erv erv_lo erv_hi authenticity reputation_band engagement_context band_row band_color band_label
      reason_codes confirmed_anomaly cold_start_tier confidence_marker calibrated
    ].each { |col| remove_column :trust_index_histories, col, if_exists: true }

    # NB: restoring trust_index_score NOT NULL requires zero v2 (null-scalar) rows present —
    # a prod rollback with v2 rows written must purge/backfill them first (M1 is pre-cutover).
    change_column_null :trust_index_histories, :trust_index_score, false
  end
end
