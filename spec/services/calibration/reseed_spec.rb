# frozen_string_literal: true

require "rails_helper"
require "tmpdir"

RSpec.describe Calibration::Reseed do
  let(:jc) { described_class::Cell.new(category: "just_chatting", v_bucket: "1k-5k", chat_mode: "open", language: "RU") }
  let(:gaming) { described_class::Cell.new(category: "gaming", v_bucket: "0-1k", chat_mode: "open", language: "RU") }

  # One stream's verdicts in one cell. Stream-level facts default to a clean honest partner anchor.
  def obs(channel:, rhos:, cell: jc, stream: SecureRandom.uuid, partner: true, full_tier: true, accused: false,
          anomaly: false, q: 1.0, green_median: nil)
    described_class::Observation.new(stream_id: stream, channel_id: channel, cell: cell, rhos: rhos,
                                     green_median: green_median, partner: partner, full_tier: full_tier,
                                     accused: accused, anomaly: anomaly, q: q)
  end

  # n honest channels, one stream each, every verdict at the given value.
  def channels(values, cell: jc, prefix: "ch")
    values.each_with_index.map { |v, i| obs(channel: "#{prefix}#{i}", rhos: [ v, v, v ], cell: cell) }
  end

  # An UNSAVED row — the plan only reads attributes; nothing touches the table.
  def current_row(cell, star:, lo:, hi:, calibrated: true)
    CalibrationCellBaseline.new(**cell.to_h, rho_star: star, rho_lo: lo, rho_hi: hi, sample_size: 11, calibrated: calibrated)
  end

  def plan_for(observations, current: [], fleet: [], **opts)
    described_class.plan(observations: observations, current: current, fleet: fleet, **opts)
  end

  def cell_plan(plan, cell = jc)
    plan.cells.find { |c| c.cell == cell }
  end

  describe "quantiles" do
    it "seeds ρ_lo/ρ*/ρ_hi as nearest-rank P10/P50/P90 of the per-channel votes (canon aggregate_windowed.rb)" do
      values = (10..19).map { |i| i / 100.0 } # 0.10 .. 0.19, n = 10
      cp = cell_plan(plan_for(channels(values)))

      # sorted[round(p·(n−1))]: P10 → idx 1, P50 → idx round(4.5)=5, P90 → idx round(8.1)=8
      expect(cp.proposed.to_h).to eq(rho_star: 0.15, rho_lo: 0.11, rho_hi: 0.18, sample_size: 10)
      expect(cp.status).to eq(:new)
      expect(cp.apply?).to be(true)
      expect(cp.notes.join).to include("maturity") # 10 < 12: applied but flagged thin
    end

    it "drops votes above the outlier guard before quantiles and reports them" do
      plan = plan_for(channels([ 0.2 ] * 8 + [ 3.5 ]))
      cp = cell_plan(plan)

      expect(cp.n_channels).to eq(8)
      expect(cp.proposed.rho_hi).to eq(0.2)
      expect(plan.dropped_outliers).to eq(jc.key => 1)
    end
  end

  describe "per-channel de-duplication" do
    it "gives a channel ONE vote however many streams it contributed" do
      chatty = Array.new(20) { obs(channel: "chatty", rhos: [ 0.9, 0.9, 0.9 ]) }
      plan = plan_for(chatty + channels([ 0.2 ] * 9))
      cp = cell_plan(plan)

      expect(cp.n_channels).to eq(10)
      expect(cp.proposed.rho_star).to eq(0.2) # 20 streams of 0.9 would own the median without de-dup
    end

    it "votes the median of the channel's stream medians" do
      multi = [ 0.1, 0.3, 0.5 ].map { |v| obs(channel: "multi", rhos: [ v, v, v ]) }
      others = channels([ 0.3 ] * 7)
      cp = cell_plan(plan_for(multi + others))

      expect(cp.n_channels).to eq(8)
      expect(cp.proposed.rho_lo).to eq(0.3) # multi voted 0.3, not 0.1
    end

    it "ignores a (stream, cell) with fewer verdicts than min_rows" do
      thin = obs(channel: "thin", rhos: [ 0.01, 0.01 ])
      cp = cell_plan(plan_for(channels([ 0.2 ] * 8) + [ thin ]))

      expect(cp.n_channels).to eq(8)
      expect(cp.proposed.rho_lo).to eq(0.2)
    end
  end

  describe "honest filter" do
    it "drops non-partner, thin-tier, accused, anomalous and spam-roster streams — and counts why" do
      dirty = [
        obs(channel: "a", rhos: [ 0.01 ] * 3, partner: false),
        obs(channel: "b", rhos: [ 0.01 ] * 3, full_tier: false),
        obs(channel: "c", rhos: [ 0.01 ] * 3, accused: true),
        obs(channel: "d", rhos: [ 0.01 ] * 3, anomaly: true),
        obs(channel: "e", rhos: [ 0.01 ] * 3, q: 0.9)
      ]
      plan = plan_for(channels([ 0.2 ] * 8) + dirty)

      expect(plan.rejected).to eq(not_partner: 1, not_full_tier: 1, accused: 1, anomaly: 1, spam_roster: 1)
      expect(plan.honest_streams).to eq(8)
      expect(cell_plan(plan).proposed.rho_lo).to eq(0.2) # none of the 0.01 channels leaked in
    end

    it "keeps a stream whose roster spam share is unknown (q nil)" do
      plan = plan_for(channels([ 0.2 ] * 7) + [ obs(channel: "q", rhos: [ 0.2 ] * 3, q: nil) ])
      expect(cell_plan(plan).n_channels).to eq(8)
    end

    it "does NOT filter on the verdict colour (that would only confirm the live ρ*) but reports the GREEN-only median" do
      obs_list = (0...10).map { |i| obs(channel: "c#{i}", rhos: [ 0.1 ] * 3, green_median: (i < 3 ? 0.4 : nil)) }
      cp = cell_plan(plan_for(obs_list, current: [ current_row(jc, star: 0.4, lo: 0.3, hi: 0.6) ]))

      expect(cp.proposed.rho_star).to eq(0.1)
      expect(cp.green_only_star).to eq(0.4)
    end
  end

  describe "min-n" do
    it "does not re-seed a new cell below min_channels (indicative quantiles only)" do
      cp = cell_plan(plan_for(channels([ 0.2 ] * 7)))

      expect(cp.status).to eq(:thin)
      expect(cp.apply?).to be(false)
      expect(cp.proposed.rho_star).to eq(0.2) # shown for the report, never written
    end

    it "holds an existing cell as is when the corpus is too thin to re-seed it" do
      cp = cell_plan(plan_for(channels([ 0.2 ] * 5), current: [ current_row(jc, star: 0.33, lo: 0.17, hi: 0.44) ]))

      expect(cp.status).to eq(:held_thin)
      expect(cp.apply?).to be(false)
      expect(cp.now.rho_star).to eq(0.33)
    end

    it "honours a custom min_channels" do
      expect(cell_plan(plan_for(channels([ 0.2 ] * 5), min_channels: 5)).status).to eq(:new)
    end

    # RESEED_MIN_CHANNELS is an ENV knob; below INDICATIVE_MIN a cell would clear the n-gate with no
    # quantiles computed for it at all, and status_for would read rho_lo off nil.
    it "refuses a min_channels below the indicative floor instead of planning a cell it cannot propose" do
      expect { plan_for(channels([ 0.2 ] * 2), min_channels: 2) }
        .to raise_error(ArgumentError, /below INDICATIVE_MIN=3/)
    end

    it "still accepts min_channels exactly at the indicative floor" do
      expect(cell_plan(plan_for(channels([ 0.2 ] * 3), min_channels: 3)).status).to eq(:new)
    end
  end

  describe "diff against the live cells" do
    it "marks an existing cell :update and reports honest verdicts below ρ_lo now vs proposed" do
      values = [ 0.10, 0.12, 0.13, 0.14, 0.15, 0.16, 0.17, 0.18, 0.20, 0.22 ]
      cp = cell_plan(plan_for(channels(values), current: [ current_row(jc, star: 0.33, lo: 0.17, hi: 0.44) ]))

      expect(cp.status).to eq(:update)
      expect(cp.now.source).to eq(:exact)
      expect(cp.honest_below_lo_now).to eq(0.6)   # 6 of 10 channels (all their verdicts) sit under 0.17
      expect(cp.honest_below_lo_new).to eq(0.1)   # new ρ_lo = 0.12 → only the 0.10 channel
    end

    it "resolves an uncovered cell to the engine DEFAULT (uncalibrated) as 'now'" do
      cp = cell_plan(plan_for(channels([ 0.2 ] * 8, cell: gaming), current: []), gaming)

      expect(cp.now.source).to eq(:engine_default)
      expect(cp.now.calibrated).to be(false)
      expect(cp.status).to eq(:new)
    end

    it "refuses a cell that does not accuse today and whose new ρ_lo would clear the absolute gate" do
      spread = (0...10).map { |i| obs(channel: "s#{i}", rhos: [ 0.01, 0.5, 0.5 ]) } # medians 0.5, a third of verdicts at 0.01
      cp = cell_plan(plan_for(spread)) # no current row → engine DEFAULT, uncalibrated → accuses nobody now

      expect(cp.status).to eq(:unsafe)
      expect(cp.apply?).to be(false)
      expect(cp.honest_yellow_zone_now).to eq(0.0)
      expect(cp.honest_yellow_zone_new).to be_within(1e-9).of(1 / 3.0)
    end

    # Votes are all 0.20 (each channel's stream median), so the proposal is lo=star=hi=0.20 and the
    # YELLOW zone after is ρ_obs < 0.16 — the 0.05 verdict of each channel, a third of the traffic.
    let(:third_exposed) { (0...10).map { |i| obs(channel: "s#{i}", rhos: [ 0.05, 0.20, 0.20 ]) } }

    it "applies a stale-high cell whose re-seed NARROWS honest exposure, even above the absolute gate" do
      # ρ_lo 0.60 today puts EVERY one of these honest verdicts in the YELLOW zone (all < 0.48); the
      # re-seed cuts that to a third. Over the 10% bar either way — refusing it strands the other 2/3.
      cp = cell_plan(plan_for(third_exposed, current: [ current_row(jc, star: 0.9, lo: 0.6, hi: 1.2) ]))

      expect(cp.honest_yellow_zone_now).to eq(1.0)
      expect(cp.honest_yellow_zone_new).to be_within(1e-9).of(1 / 3.0)
      expect(cp.status).to eq(:update)
      expect(cp.apply?).to be(true)
      expect(cp.notes.join).to include("NARROWER than today")
    end

    it "still refuses a calibrated cell whose re-seed WIDENS honest exposure past the bar" do
      # ρ_lo 0.01 today accuses nobody here (nothing is under 0.008); the re-seed would lift ρ_lo to
      # 0.20 and newly expose a third of the honest traffic. Narrower is the only excuse for clearing
      # the bar, and this is wider.
      cp = cell_plan(plan_for(third_exposed, current: [ current_row(jc, star: 0.015, lo: 0.01, hi: 0.02) ]))

      expect(cp.honest_yellow_zone_now).to eq(0.0)
      expect(cp.honest_yellow_zone_new).to be_within(1e-9).of(1 / 3.0)
      expect(cp.status).to eq(:unsafe)
      expect(cp.apply?).to be(false)
      expect(cp.notes.join).to include("widens exposure")
    end
  end

  describe "fleet effect" do
    it "reports verdicts/hour and the AMBER-by-deficit / YELLOW-zone shares now vs after apply" do
      current = [ current_row(jc, star: 0.40, lo: 0.20, hi: 0.60) ]
      fleet = [ described_class::FleetObservation.new(cell: jc, verdicts: 120, rhos: [ 0.10, 0.15, 0.25, 0.50 ], full_tier: true) ]
      cp = cell_plan(plan_for(channels([ 0.15 ] * 8), current: current, fleet: fleet, fleet_hours: 1.0))

      expect(cp.fleet.verdicts_per_hour).to eq(120.0)
      expect(cp.fleet.amber_now).to eq(0.75)       # < 0.8·0.40 = 0.32 → 0.10, 0.15, 0.25
      expect(cp.fleet.amber_new).to eq(0.25)       # < 0.8·0.15 = 0.12 → 0.10
      expect(cp.fleet.yellow_zone_now).to eq(0.5)  # < 0.8·0.20 = 0.16 → 0.10, 0.15
      expect(cp.fleet.yellow_zone_new).to eq(0.25) # < 0.8·0.15 = 0.12 → 0.10
    end
  end

  describe ".run" do
    let(:corpus) do
      Calibration::ReseedCorpus::Result.new(observations: channels((10..19).map { |i| i / 100.0 }), current: CalibrationCellBaseline.all.to_a,
                                            fleet: [], fleet_hours: 1.0, meta: { window: "spec" })
    end
    let!(:existing) do
      CalibrationCellBaseline.create!(category: jc.category, v_bucket: jc.v_bucket, chat_mode: jc.chat_mode,
                                      language: jc.language, rho_star: 0.328, rho_lo: 0.174, rho_hi: 0.444,
                                      sample_size: 9, calibrated: true)
    end
    let(:out) { StringIO.new }

    it "dryrun writes nothing — no cell row, no snapshot file" do
      Dir.mktmpdir do |dir|
        before = CalibrationCellBaseline.order(:id).map(&:attributes)
        res = described_class.run(mode: "dryrun", corpus_loader: -> { corpus }, snapshot_dir: dir, io: out)

        expect(CalibrationCellBaseline.order(:id).map(&:attributes)).to eq(before)
        expect(Dir.children(dir)).to be_empty
        expect(res[:snapshot]).to be_nil
        expect(cell_plan(res[:plan]).status).to eq(:update)
        expect(out.string).to include(jc.key).and include("JSON ")
      end
    end

    it "refuses apply without CONFIRM_RESEED=yes before even loading the corpus" do
      loader = -> { raise "corpus must not be loaded for a refused apply" }

      expect { described_class.run(mode: "apply", confirm: nil, corpus_loader: loader, io: out) }
        .to raise_error(described_class::Refused, /CONFIRM_RESEED=yes/)
      expect(existing.reload.rho_star.to_f).to eq(0.328)
    end

    it "rejects an unknown mode" do
      expect { described_class.run(mode: "yolo", corpus_loader: -> { corpus }, io: out) }.to raise_error(ArgumentError)
    end

    it "apply writes the cells in one go and the snapshot restores them exactly" do
      gaming_obs = channels([ 0.25 ] * 8, cell: gaming, prefix: "g")
      corpus2 = corpus.with(observations: corpus.observations + gaming_obs)

      Dir.mktmpdir do |dir|
        res = described_class.run(mode: "apply", confirm: "yes", corpus_loader: -> { corpus2 }, snapshot_dir: dir, io: out)

        expect(existing.reload.rho_star.to_f).to eq(0.15)
        expect(existing.sample_size).to eq(10)
        created = CalibrationCellBaseline.find_by(category: "gaming", v_bucket: "0-1k", chat_mode: "open", language: "RU")
        expect([ created.rho_star.to_f, created.calibrated ]).to eq([ 0.25, true ])
        expect(JSON.parse(File.read(res[:snapshot]))["cells"].size).to eq(2)

        described_class.restore!(res[:snapshot])

        existing.reload
        expect([ existing.rho_star, existing.rho_lo, existing.rho_hi ].map(&:to_f)).to eq([ 0.328, 0.174, 0.444 ])
        expect(existing.sample_size).to eq(9)
        expect(CalibrationCellBaseline.find_by(category: "gaming", v_bucket: "0-1k")).to be_nil # apply created it → restore deletes it
      end
    end
  end
end
