# frozen_string_literal: true

require "rails_helper"

# The loader half of the ρ* re-seed. It decides WHICH persisted verdicts are corpus material and WHICH
# cell each one belongs to — neither of which Calibration::Reseed can check: the planner does its
# arithmetic faithfully on whatever it is handed, so a mistake here is silent all the way to an apply.
RSpec.describe Calibration::ReseedCorpus do
  let(:conn) { ActiveRecord::Base.connection }
  let(:now) { Time.current.change(usec: 0) }

  # plan_guard: false — a near-empty test table always plans as a sequential scan, which is precisely
  # what the guard refuses in production; it gets its own examples below, with the plan stubbed.
  def corpus(**opts)
    described_class.new(until_at: now, window_days: 1, plan_guard: false, **opts)
  end

  def partner = create(:channel, broadcaster_type: "partner")

  def stream_for(channel, game: "Just Chatting", language: "RU")
    create(:stream, channel: channel, game_name: game, language: language)
  end

  # One (stream, cell) worth of verdicts, all at the same ρ_obs, inside the window and outside the
  # last-hour fleet range. EIHC is derived from ρ_obs × V_eff the way the engine emits it, so the
  # cell stays put (V_eff 3000 → 1k-5k) while ρ_obs varies — which is what the corpus is about.
  def verdicts(channel:, stream:, rho_obs: 0.2, v_eff: 3_000, ccv: nil, count: 3, at: nil, **attrs)
    from = at || (now - 3.hours)
    Array.new(count) do |i|
      create(:trust_index_history, channel: channel, stream: stream, calculated_at: from + i.minutes,
             rho_convention: "windowed", rho_obs: rho_obs, eihc: (rho_obs * v_eff).round(2),
             ccv: ccv || v_eff, q_score: 0.97, **attrs)
    end
  end

  # An honest partner anchor: one channel, one stream, `count` identical verdicts.
  def anchor(rho_obs:, channel: nil, **attrs)
    ch = channel || partner
    verdicts(channel: ch, stream: stream_for(ch), rho_obs: rho_obs, **attrs)
    ch
  end

  describe ".v_bucket_sql" do
    def bucket(expr)
      conn.select_value("SELECT #{described_class.v_bucket_sql(expr)}")
    end

    it "puts every boundary on the same side as the Ruby bucketer it is generated from" do
      [ 1, 999, 1_000, 4_999, 5_000, 19_999, 20_000, 123_456 ].each do |v|
        expect(bucket(v)).to eq(TrustIndex::V2::CellKey.v_bucket(v)), "V=#{v}"
      end
    end

    it "collapses a missing or non-positive V to the '0' bucket rather than a real size" do
      expect(bucket("NULL::numeric")).to eq("0")
      expect(bucket(0)).to eq("0")
      expect(bucket(-1)).to eq("0")
    end
  end

  describe "V_EFF_SQL" do
    def v_eff(eihc:, rho_obs:, ccv:)
      conn.select_value(<<~SQL).to_i
        SELECT #{described_class::V_EFF_SQL}
        FROM (VALUES (#{eihc}::numeric, #{rho_obs}::numeric, #{ccv}::integer)) AS t(eihc, rho_obs, ccv)
      SQL
    end

    # ρ_obs = EIHC / V_eff with V_eff = min(V_W, V_inst), so the division recovers the V the engine
    # bucketed the cell on — not the instant CCV stored next to it.
    it "recovers the V the engine divided by, not the instant CCV" do
      expect(v_eff(eihc: 600, rho_obs: 0.2, ccv: 50)).to eq(3_000)
      expect(v_eff(eihc: 25, rho_obs: 0.5, ccv: 9_999)).to eq(50)
    end

    it "falls back to the instant CCV when there is no ratio to invert" do
      expect(v_eff(eihc: 0, rho_obs: 0.2, ccv: 1_234)).to eq(1_234)      # no chatters
      expect(v_eff(eihc: 600, rho_obs: 0, ccv: 1_234)).to eq(1_234)      # no ratio
      expect(v_eff(eihc: "NULL", rho_obs: "NULL", ccv: 1_234)).to eq(1_234)
    end
  end

  describe "#fit_since — the WINDOW is what fits the IO budget" do
    def hours_kept(io_budget_mb:, rows_per_hour:, bytes_per_row: 500.0, window_days: 7)
      c = corpus(window_days: window_days, io_budget_mb: io_budget_mb)
      (now - c.send(:fit_since, bytes_per_row, rows_per_hour)) / 3600.0
    end

    it "keeps the whole requested window when it fits" do
      expect(hours_kept(io_budget_mb: 900, rows_per_hour: 1_000)).to eq(168.0) # 7d × 1k/h × 500 B = 84 MB
    end

    it "shortens the window to what the budget affords — there is no density to thin" do
      # 900 MiB / (27k rows/h × 500 B) ≈ 69.9 h, the live shape of the run
      expect(hours_kept(io_budget_mb: 900, rows_per_hour: 27_000).round(1)).to eq(69.9)
    end

    it "never shrinks past MIN_WINDOW_HOURS, where the thin cells lose every channel they have" do
      expect(hours_kept(io_budget_mb: 1, rows_per_hour: 500_000)).to eq(described_class::MIN_WINDOW_HOURS.to_f)
    end
  end

  describe "the EXPLAIN guard" do
    let(:guarded) { described_class.new(until_at: now, plan_guard: true) }

    def stub_plan(*lines)
      allow(ActiveRecord::Base.connection).to receive(:select_values).and_return(lines)
    end

    it "refuses to run a query the planner would answer with a sequential scan of the big table" do
      stub_plan("Finalize GroupAggregate  (cost=0.00..1.00 rows=1 width=8)",
                "  ->  Parallel Seq Scan on trust_index_histories t  (cost=0.00..1.00 rows=7900000 width=8)")

      expect { guarded.send(:guard_plan!, "SELECT 1") }
        .to raise_error(/sequential scan of trust_index_histories/)
    end

    it "lets an index-range plan through" do
      stub_plan("GroupAggregate  (cost=0.00..1.00 rows=1 width=8)",
                "  ->  Parallel Index Scan using index_trust_index_histories_on_calculated_at " \
                "on trust_index_histories t  (cost=0.00..1.00 rows=1000 width=8)")

      expect { guarded.send(:guard_plan!, "SELECT 1") }.not_to raise_error
    end

    it "does not ask for a plan at all when the guard is off" do
      expect(ActiveRecord::Base.connection).not_to receive(:select_values)
      corpus.send(:guard_plan!, "SELECT 1")
    end
  end

  describe "#load" do
    it "keys the cell off the recovered V, the stream's game and the channel's chat settings" do
      ch = partner
      verdicts(channel: ch, stream: stream_for(ch), rho_obs: 0.2, v_eff: 3_000, ccv: 50)

      obs = corpus.load.observations
      expect(obs.size).to eq(1)
      expect(obs.first.cell.to_h).to eq(category: "just_chatting", v_bucket: "1k-5k", chat_mode: "open", language: "RU")
      expect(obs.first.rhos).to eq([ 0.2, 0.2, 0.2 ])
      expect(obs.first.channel_id).to eq(ch.id)
    end

    it "reads the chat mode off the channel's protection config" do
      ch = partner
      ChannelProtectionConfig.create!(channel: ch, subs_only_enabled: true)
      verdicts(channel: ch, stream: stream_for(ch))

      expect(corpus.load.observations.first.cell.chat_mode).to eq("sub-only")
    end

    it "counts a verdict whose V is under min_v but takes no ρ_obs from it" do
      ch = partner
      verdicts(channel: ch, stream: stream_for(ch), rho_obs: 0.2, v_eff: 20) # V_eff 20 < min_v 50

      obs = corpus.load.observations
      expect(obs.first.cell.v_bucket).to eq("0-1k")
      expect(obs.first.rhos).to be_empty
    end

    it "takes no ρ_obs from the cumulative convention — ρ* only ever divides the windowed frame" do
      ch = partner
      verdicts(channel: ch, stream: stream_for(ch), rho_convention: "cumulative")

      expect(corpus.load.observations.first.rhos).to be_empty
    end

    # STREAM-level: one accusatory verdict disqualifies the whole stream, in every bucket it crossed.
    it "marks a stream accused off an accusatory band row anywhere in it" do
      ch = partner
      s = stream_for(ch)
      verdicts(channel: ch, stream: s)
      verdicts(channel: ch, stream: s, at: now - 2.hours, count: 1, band_row: 2, band_color: "yellow")

      expect(corpus.load.observations.map(&:accused)).to eq([ true ])
    end

    it "marks a stream accused off a corroborator flag even when its band never left green" do
      ch = partner
      verdicts(channel: ch, stream: stream_for(ch), c_hard: true)

      expect(corpus.load.observations.first.accused).to be(true)
    end

    it "leaves a clean stream unaccused" do
      anchor(rho_obs: 0.2)
      expect(corpus.load.observations.first.accused).to be(false)
    end

    it "hands the planner an accused stream already flagged, so the honest filter drops it" do
      anchor(rho_obs: 0.2)
      anchor(rho_obs: 0.01, band_row: 1, band_color: "red")

      plan = Calibration::Reseed.plan(observations: corpus.load.observations, current: [], min_channels: 3)
      expect(plan.rejected).to eq(accused: 1)
      expect(plan.honest_streams).to eq(1)
    end

    it "reads only partner anchors — a non-partner channel is not corpus material at all" do
      affiliate = create(:channel, broadcaster_type: "affiliate")
      verdicts(channel: affiliate, stream: stream_for(affiliate))

      expect(corpus.load.observations).to be_empty
    end

    it "reads only the v2 engine, and only inside the window" do
      ch = partner
      verdicts(channel: ch, stream: stream_for(ch), at: now - 40.days)     # before @since
      verdicts(channel: ch, stream: stream_for(ch), at: now + 1.hour)      # after @until
      verdicts(channel: ch, stream: stream_for(ch), engine_version: "v1")  # retired engine

      expect(corpus.load.observations).to be_empty
    end

    # The corpus keeps one observation per (stream, cell); the planner medians the stream medians so a
    # channel that streamed all week cannot outvote one that streamed once. That only works if the
    # loader does NOT merge a channel's streams into one row here.
    it "keeps a channel's streams apart so the planner can give the channel ONE vote" do
      busy = partner
      verdicts(channel: busy, stream: stream_for(busy), rho_obs: 0.1) # same V_eff → same cell,
      verdicts(channel: busy, stream: stream_for(busy), rho_obs: 0.3) # two different streams
      anchor(rho_obs: 0.5)
      anchor(rho_obs: 0.9)

      obs = corpus.load.observations
      expect(obs.count { |o| o.channel_id == busy.id }).to eq(2)
      expect(obs.select { |o| o.channel_id == busy.id }.map(&:stream_id).uniq.size).to eq(2)

      # votes = [0.2 (busy: median of 0.1 and 0.3), 0.5, 0.9] → P10 idx 0, P50 idx 1, P90 idx 2
      cp = Calibration::Reseed.plan(observations: obs, current: [], min_channels: 3).cells.first
      expect(cp.n_channels).to eq(3)
      expect(cp.proposed.to_h).to eq(rho_star: 0.5, rho_lo: 0.2, rho_hi: 0.9, sample_size: 3)
    end

    it "reports the corpus it read in the meta the operator signs off on" do
      anchor(rho_obs: 0.2)
      meta = corpus.load.meta

      expect(meta[:corpus]).to include("3 sampled v2 verdicts", "1 streams (1 partner)", "3 usable")
      expect(meta[:current_cells]).to include("with parent — any is a refusal")
      expect(meta[:est_heap_read]).to include("FLOOR")
    end
  end
end
