# frozen_string_literal: true

require "rails_helper"

# T1-074 (TI v2) M1 — proves the additive schema shipped (columns / tables / nullability / defaults)
# beyond the model specs. A schema regression (dropped column, wrong nullability, non-partial index)
# fails HERE even though PR1 has no v2 runtime reader yet. Guard: PR1 schema is the scope-frozen
# SRS §5.1 contract — silent drift would break the not-yet-built engine.
RSpec.describe "TI v2 M1 additive schema", type: :model do
  let(:conn) { ActiveRecord::Base.connection }
  let(:v2_tih_columns) do
    %w[
      erv erv_lo erv_hi f_hard f_hard_lo f_hard_hi f_soft f_soft_lo f_soft_hi f_self f_hat f_hat_lo
      f_hat_hi authenticity authenticity_lo authenticity_hi n_frac q_score eihc rho_obs rho_self
      rho_self_lo cps band_row band_sub band_color reason_codes c_hard c_self i_event
      confirmed_anomaly confidence_marker cold_start_tier engine_version
    ]
  end

  it "adds all 34 v2 columns to trust_index_histories" do
    cols = conn.columns(:trust_index_histories).map(&:name)
    expect(v2_tih_columns.size).to eq(34)
    expect(v2_tih_columns - cols).to be_empty
  end

  it "makes trust_index_score nullable (v2 rows carry no TI-scalar)" do
    col = conn.columns(:trust_index_histories).find { |c| c.name == "trust_index_score" }
    expect(col.null).to be(true)
  end

  it "defaults engine_version to 'v1' NOT NULL (fail-safe; ADR MF-4 supersedes SRS 'v2')" do
    col = conn.columns(:trust_index_histories).find { |c| c.name == "engine_version" }
    expect(col.default).to eq("v1")
    expect(col.null).to be(false)
  end

  it "makes the plashka corroboration flags NOT NULL" do
    by_name = conn.columns(:trust_index_histories).index_by(&:name)
    %w[c_hard c_self i_event confirmed_anomaly reason_codes].each do |f|
      expect(by_name.fetch(f).null).to be(false)
    end
  end

  it "creates the 3 calibration/evidence tables with their unique keys" do
    expect(conn.table_exists?(:calibration_constants)).to be(true)
    expect(conn.table_exists?(:calibration_cell_baselines)).to be(true)
    expect(conn.table_exists?(:named_bot_evidences)).to be(true)
    expect(conn.index_exists?(:calibration_constants, :key, unique: true)).to be(true)
    expect(conn.index_exists?(:calibration_cell_baselines,
                              %i[category v_bucket chat_mode language], unique: true)).to be(true)
  end

  it "named_bot_evidences carries the ADR DEC-5 FK columns incl. dispute-grace score_dispute_id" do
    by_name = conn.columns(:named_bot_evidences).index_by(&:name)
    expect(by_name["channel_id"].null).to be(false)               # NOT NULL FK
    expect(by_name["trust_index_history_id"].null).to be(false)   # snapshot linkage NOT NULL
    expect(by_name["stream_id"].null).to be(true)                 # nullable (live aggregate)
    expect(by_name).to have_key("score_dispute_id")               # retention-exempt (N-3)
    expect(conn.index_exists?(:named_bot_evidences, :score_dispute_id)).to be(true)
  end

  it "adds the PARTIAL v2 backfill-progress index (WHERE engine_version='v2')" do
    idx = conn.indexes(:trust_index_histories).find { |i| i.name == "idx_tih_v2_backfill_progress" }
    expect(idx).to be_present
    expect(idx.where).to include("engine_version")
  end
end
