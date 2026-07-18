# frozen_string_literal: true

# T1-074 (TI v2) — M1 additive schema. Exact realization of the scope-frozen SRS §5.1 schema
# (34 ADD columns on trust_index_histories + 3 new tables) / ADR DEC-3 (ADD, not sibling) /
# DEC-4 step 1 (migration ordering) / DEC-7 (dual-run engine_version discriminator).
#
# Adds the v2 engine outputs to trust_index_histories (ADD, not a sibling table — the MV
# `latest_tih_per_stream` needs DROP/CREATE in the sibling option too, so the sibling's clean-drop
# advantage is illusory; ADD avoids a join on every API read — DEC-3), makes trust_index_score
# NULLABLE (v2 rows carry no TI-scalar — fraud is `ERV = V − F̂`, not `TI = 100 − bot_score`), and
# creates the 3 v2 tables: calibration_constants (flat key→value config, UNIQUE key) +
# calibration_cell_baselines (per-cell ρ*, hierarchical parent_cell_id) + named_bot_evidence
# (immutable dispute-safe P5 evidence linked to its emitting snapshot — SRS §5.1, EC-13, AC-6).
#
# ADDITIVE + REVERSIBLE only. The MV `latest_tih_per_stream` recreate + legacy-column DROP =
# M2 follow-up TASK after confirmed cutover (ADR DEC-4 step 7) — NOT here.
#
# engine_version defaults 'v1' — ADR MF-4 (fail-safe) SUPERSEDES SRS §5.1 line 501's 'v2' default:
# with a 'v2' default a forgotten write in the legacy path silently masquerades as v2 → poisons the
# shadow-diff and the Reputation basis-filter (`WHERE engine_version='v2'`). Existing + legacy rows
# read as v1 with no code change; the v2 engine writes 'v2' explicitly. All v2 output columns
# nullable (v1 rows leave them null; v2 rows leave the retired TI-scalar null); plashka flags +
# reason_codes are NOT NULL with safe defaults (false / []).

class TiV2M1AdditiveSchema < ActiveRecord::Migration[8.0]
  disable_ddl_transaction!

  TIH = :trust_index_histories

  def up
    # ── engine discriminator + make the retired scalar nullable (DEC-4 step 1, guarded) ──
    add_column TIH, :engine_version, :string, limit: 8, null: false, default: "v1", if_not_exists: true
    change_column_null TIH, :trust_index_score, true if column_exists?(TIH, :trust_index_score)

    # ── L4 ERV: subtracted real-viewer count + interval (INTEGER — viewer scale, SRS §5.1) ──
    %i[erv erv_lo erv_hi].each { |c| add_column TIH, c, :integer, if_not_exists: true }

    # ── L1/L2/L3 fraud counts + intervals — DECIMAL(10,2) (SRS §5.1) ──
    %i[f_hard f_hard_lo f_hard_hi f_soft f_soft_lo f_soft_hi f_self f_hat f_hat_lo f_hat_hi].each do |c|
      add_column TIH, c, :decimal, precision: 10, scale: 2, if_not_exists: true
    end

    # ── axis 1 Authenticity A = 100·(1−F̂/V) + interval — DECIMAL(5,2) ──
    %i[authenticity authenticity_lo authenticity_hi].each do |c|
      add_column TIH, c, :decimal, precision: 5, scale: 2, if_not_exists: true
    end

    # ── named-bot fraction (V-independent) + chatter quality — DECIMAL(5,4) ──
    %i[n_frac q_score].each { |c| add_column TIH, c, :decimal, precision: 5, scale: 4, if_not_exists: true }

    # ── effective independent human chatters — DECIMAL(10,2) ──
    add_column TIH, :eihc, :decimal, precision: 10, scale: 2, if_not_exists: true

    # ── axis 3 chat_share ratios (EIHC/V, self-baseline, own-P10) — DECIMAL(6,5) ──
    %i[rho_obs rho_self rho_self_lo].each { |c| add_column TIH, c, :decimal, precision: 6, scale: 5, if_not_exists: true }

    # ── axis 3 Channel Protection Score (ex-signal, 0-100) — INTEGER ──
    add_column TIH, :cps, :integer, if_not_exists: true

    # ── L4 band (§D 6-row table): row 1-6 (SMALLINT), sub 6a/6b, color ──
    add_column TIH, :band_row, :integer, limit: 2, if_not_exists: true
    add_column TIH, :band_sub, :string, limit: 2, if_not_exists: true
    add_column TIH, :band_color, :string, limit: 8, if_not_exists: true

    # ── L4 reason codes (legal-safe) + plashka corroboration flags (NOT NULL, safe defaults) ──
    add_column TIH, :reason_codes, :jsonb, null: false, default: [], if_not_exists: true
    add_column TIH, :c_hard, :boolean, null: false, default: false, if_not_exists: true             # N_frac ≥ φ_yellow
    add_column TIH, :c_self, :boolean, null: false, default: false, if_not_exists: true             # I = 1
    add_column TIH, :i_event, :boolean, null: false, default: false, if_not_exists: true            # inflation event fired
    add_column TIH, :confirmed_anomaly, :boolean, null: false, default: false, if_not_exists: true  # plashka shown (C_hard ∨ C_self)

    # ── cold-start (3-tier, replaces 5-value cold_start_status) + confidence marker ──
    add_column TIH, :confidence_marker, :string, limit: 12, if_not_exists: true                     # reliable / provisional
    add_column TIH, :cold_start_tier, :string, limit: 12, if_not_exists: true                       # insufficient / basic / full

    # ── partial index for backfill-progress / shadow-compare (only v2 rows) — SRS §5.1 L518 / ADR L422 ──
    add_index TIH, %i[channel_id calculated_at],
      where: "engine_version = 'v2'",
      name: "idx_tih_v2_backfill_progress", algorithm: :concurrently, if_not_exists: true

    # ── calibration_constants: flat key→value config (illustrative until GATE 0) — SRS §5.1 ──
    # φ/τ/q/π0/z*/g*/LLR are GLOBAL scalars (UNIQUE key); per-cell ρ* lives in calibration_cell_baselines.
    create_table :calibration_constants, id: :uuid, if_not_exists: true do |t|
      t.string :key, null: false, limit: 64
      t.decimal :value, precision: 10, scale: 6, null: false
      t.boolean :calibrated, null: false, default: false               # true after GATE 0 ingest
      t.string :source, null: false, limit: 32, default: "illustrative" # illustrative / gate0_holdout
      t.timestamps
    end
    add_index :calibration_constants, :key, unique: true,
      name: "idx_calibration_constants_key", if_not_exists: true

    # ── calibration_cell_baselines: per-cell ρ* (category × V-bucket × chat-mode × language) — SRS §5.1 ──
    # rho_star (median → moves the ERV number), rho_lo (P5-10, honest≈0 → gates the label), rho_hi (interval).
    # Sparse cell resolves up the parent_cell_id chain (hierarchical shrinkage, R-007).
    create_table :calibration_cell_baselines, id: :uuid, if_not_exists: true do |t|
      t.string :category, null: false, limit: 64
      t.string :v_bucket, null: false, limit: 16   # <100 / 100-1k / 1k-5k / 5k+
      t.string :chat_mode, null: false, limit: 16  # open / sub-only / followers-only / slow / emote-only
      t.string :language, null: false, limit: 8
      t.decimal :rho_star, precision: 6, scale: 5, null: false
      t.decimal :rho_lo, precision: 6, scale: 5, null: false
      t.decimal :rho_hi, precision: 6, scale: 5, null: false
      t.integer :sample_size, null: false, default: 0                        # hierarchical shrinkage weight
      t.references :parent_cell, type: :uuid, index: false,
        foreign_key: { to_table: :calibration_cell_baselines }               # fallback for sparse cell
      t.boolean :calibrated, null: false, default: false
      t.timestamps
    end
    add_index :calibration_cell_baselines, %i[category v_bucket chat_mode language], unique: true,
      name: "idx_calibration_cell_baselines_key", if_not_exists: true

    # ── named_bot_evidence: immutable dispute-safe P5 evidence (ADR DEC-5 / SRS §5.1, FR-009, EC-13, AC-6) ──
    # Written only on C_hard. Linked to its emitting snapshot (trust_index_history_id) so a 40-day
    # dispute is reproducible even after raw rotates / GATE 0 recalibrates τ_hard. stream_id nullable
    # (live-aggregate evidence has no per-broadcast stream). Retention = Rolling Window (30/90) +
    # dispute-grace (N-3): a dispute filed near the 90-day edge could rotate evidence out mid-dispute,
    # so rows tied to an open score_dispute (FK score_dispute_id) are retention-exempt until it closes
    # (TASK-133 cleanup excludes `WHERE score_dispute_id IS NOT NULL AND dispute.status = open`).
    create_table :named_bot_evidences, id: :uuid, if_not_exists: true do |t|
      t.references :channel, type: :uuid, null: false, foreign_key: true, index: false
      t.references :stream, type: :uuid, null: true, foreign_key: true, index: false
      t.references :trust_index_history, type: :uuid, null: false, foreign_key: true, index: false
      t.string :username, null: false, limit: 64                 # public Twitch login (∈ B_hard∩chatters)
      t.decimal :p_u, precision: 5, scale: 4, null: false        # per-identity posterior at flag time
      t.string :evidence_reason, null: false, limit: 48          # temporal_cross_channel / known_bot / per_user_scorer
      t.datetime :calculated_at, null: false, default: -> { "now()" }
      t.references :score_dispute, type: :uuid, null: true, foreign_key: true, index: false # retention-exempt while dispute open (N-3)
    end
    add_index :named_bot_evidences, %i[channel_id calculated_at],
      name: "idx_named_bot_evidence_channel_time", if_not_exists: true
    add_index :named_bot_evidences, :trust_index_history_id,
      name: "idx_named_bot_evidence_tih", if_not_exists: true
    add_index :named_bot_evidences, :score_dispute_id,
      name: "idx_named_bot_evidence_dispute", if_not_exists: true
  end

  def down
    drop_table :named_bot_evidences, if_exists: true
    drop_table :calibration_cell_baselines, if_exists: true
    drop_table :calibration_constants, if_exists: true

    remove_index TIH, name: "idx_tih_v2_backfill_progress", if_exists: true
    %i[
      engine_version erv erv_lo erv_hi
      f_hard f_hard_lo f_hard_hi f_soft f_soft_lo f_soft_hi f_self f_hat f_hat_lo f_hat_hi
      authenticity authenticity_lo authenticity_hi n_frac q_score eihc rho_obs rho_self rho_self_lo
      cps band_row band_sub band_color reason_codes c_hard c_self i_event confirmed_anomaly
      confidence_marker cold_start_tier
    ].each { |col| remove_column TIH, col, if_exists: true }

    # NB: restoring trust_index_score NOT NULL requires zero v2 (null-scalar) rows present —
    # a prod rollback with v2 rows written must purge/backfill them first (M1 is pre-cutover).
    change_column_null TIH, :trust_index_score, false if column_exists?(TIH, :trust_index_score)
  end
end
