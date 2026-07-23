# frozen_string_literal: true

require "rails_helper"

RSpec.describe SignalComputeWorker do
  let(:worker) { described_class.new }
  let(:channel) { Channel.create!(twitch_id: "scw_ch", login: "scw_channel", display_name: "SCW") }
  let(:stream) { Stream.create!(channel: channel, started_at: 1.hour.ago, game_name: "Just Chatting") }

  # Phase 5 follow-up regression guard (2026-05-31): the worker MUST enqueue on
  # :signal_compute (not :signals). String value (not Symbol) — Sidekiq stores option
  # values verbatim, and any drift back to :signals re-puts new TI recomputes BEHIND
  # the 1M+ historical :signals backlog → live Trust Index goes stale on every channel.
  describe "sidekiq queue" do
    it "is 'signal_compute' (String) — bypasses :signals historical backlog" do
      expect(described_class.sidekiq_options["queue"]).to eq("signal_compute"),
        "SignalComputeWorker.sidekiq_options[:queue] must be 'signal_compute' (String). " \
        "If this drifts back to 'signals', new TI recompute jobs land behind the residual " \
        "1M+ :signals backlog and live-stream TI/ERV freshness re-breaks."
    end

    it "retry count is 3 (unchanged from pre-Phase-5)" do
      expect(described_class.sidekiq_options["retry"]).to eq(3)
    end
  end

  before do
    # Permissive default for unrelated flags — keeps the spec stable as new flags are introduced.
    allow(Flipper).to receive(:enabled?).and_return(false)
    allow(Flipper).to receive(:enabled?).with(:signal_compute).and_return(true)

    # Seed minimal configs
    TiSignal::SIGNAL_TYPES.each do |type|
      SignalConfiguration.find_or_create_by!(
        signal_type: type, category: "default", param_name: "weight_in_ti"
      ) { |c| c.param_value = 1.0 / TiSignal::SIGNAL_TYPES.size }
      SignalConfiguration.find_or_create_by!(
        signal_type: type, category: "default", param_name: "alert_threshold"
      ) { |c| c.param_value = 0.5 }
    end
    SignalConfiguration.find_or_create_by!(
      signal_type: "trust_index", category: "default", param_name: "population_mean"
    ) { |c| c.param_value = 65.0 }
    %w[trusted_min needs_review_min suspicious_min].each_with_index do |param, i|
      SignalConfiguration.find_or_create_by!(
        signal_type: "trust_index", category: "default", param_name: param
      ) { |c| c.param_value = [ 80, 50, 25 ][i] }
    end
    SignalConfiguration.find_or_create_by!(
      signal_type: "trust_index", category: "default", param_name: "incident_threshold"
    ) { |c| c.param_value = 40 }
    SignalConfiguration.find_or_create_by!(
      signal_type: "auth_ratio", category: "default", param_name: "expected_min"
    ) { |c| c.param_value = 0.65 }
    SignalConfiguration.find_or_create_by!(
      signal_type: "chatter_ccv_ratio", category: "default", param_name: "expected_ratio_min"
    ) { |c| c.param_value = 0.10 }
    SignalConfiguration.find_or_create_by!(
      signal_type: "signal_compute", category: "default", param_name: "throttle_seconds"
    ) { |c| c.param_value = 30.0 }

    # 10 completed streams for full confidence
    10.times { Stream.create!(channel: channel, started_at: 3.hours.ago, ended_at: 2.hours.ago) }
  end

  it "executes full pipeline and creates TIH + ERV" do
    expect {
      worker.perform(stream.id)
    }.to change(TrustIndexHistory, :count).by(1).and change(ErvEstimate, :count).by(1)
  end

  it "skips when Flipper disabled" do
    allow(Flipper).to receive(:enabled?).with(:signal_compute).and_return(false)
    expect { worker.perform(stream.id) }.not_to change(TrustIndexHistory, :count)
  end

  it "handles missing stream gracefully" do
    expect { worker.perform("nonexistent") }.not_to raise_error
  end

  it "throttles: 2nd call within TTL skipped" do
    worker.perform(stream.id)
    expect { worker.perform(stream.id) }.not_to change(TrustIndexHistory, :count)
  end

  it "force=true skips throttle (final compute)" do
    worker.perform(stream.id)
    expect {
      worker.perform(stream.id, true)
    }.to change(TrustIndexHistory, :count).by(1)
  end

  it "logs info with the engine version and duration (engine-agnostic, DEC-7)" do
    expect(Rails.logger).to receive(:info).with(/SignalComputeWorker: stream.*engine=v1.*duration=/)
    worker.perform(stream.id)
  end

  # T1-074 PR2b — TI v2 dual-run wiring, SHADOW phase. Default (flag off) is a pure no-op: v1 only.
  # Shadow runs v2 for a LOG-only diff — it never persists (no TIH pollution) nor publishes.
  describe "TI v2 shadow branch (DEC-2/DEC-7)" do
    it "default (ti_v2_shadow off): pure v1, no v2 row" do
      expect { worker.perform(stream.id) }.to change(TrustIndexHistory, :count).by(1)
      expect(TrustIndexHistory.where(engine_version: "v2").count).to eq(0)
      expect(TrustIndexHistory.where(engine_version: "v1").count).to eq(1)
    end

    it "shadow (ti_v2_shadow ON): runs v2 + logs the v1↔v2 diff, does NOT persist v2 (no pollution)" do
      allow(Flipper).to receive(:enabled?).with(:ti_v2_shadow).and_return(true)
      allow(Rails.logger).to receive(:info)
      expect { worker.perform(stream.id) }.to change(TrustIndexHistory, :count).by(1) # v1 only
      expect(TrustIndexHistory.where(engine_version: "v2").count).to eq(0)
      expect(Rails.logger).to have_received(:info).with(/SCW shadow.*v2_band/)
      expect(Rails.logger).to have_received(:info).with(/SCW shadow.*v2_rho_conv/) # P0.5 provenance stamp
    end

    it "a v2 shadow failure never breaks the v1 live path (shadow safety)" do
      allow(Flipper).to receive(:enabled?).with(:ti_v2_shadow).and_return(true)
      allow(TrustIndex::ContextBuilder).to receive(:build_v2).and_raise(StandardError, "boom")
      expect { worker.perform(stream.id) }.to change(TrustIndexHistory, :count).by(1) # v1 still lands
      expect(TrustIndexHistory.where(engine_version: "v2").count).to eq(0)
    end

    it "shadow never touches the wire — publish_update ships the v1 legacy payload only, not v2" do
      allow(Flipper).to receive(:enabled?).with(:ti_v2_shadow).and_return(true)
      published = []
      fake_redis = instance_double(Redis)
      allow(fake_redis).to receive(:set).and_return(true) # throttle acquire + signal-health
      allow(fake_redis).to receive(:publish) { |_ch, payload| published << payload }
      allow(worker).to receive(:redis).and_return(fake_redis)

      worker.perform(stream.id)

      expect(published.size).to eq(1)
      parsed = JSON.parse(published.first)
      expect(parsed).to include("ti_score", "timestamp")
      expect(parsed).to include("engine_version" => "v1")
      expect(parsed.keys).not_to include("erv", "band", "axes", "authenticity") # no v2 headline leak
    end

    it "MF-4: legacy v1 persist tags engine_version='v1' explicitly (defense-in-depth over the 'v1' default)" do
      worker.perform(stream.id)
      expect(TrustIndexHistory.last.engine_version).to eq("v1")
    end
  end

  # T1-074 PR3b — the CUTOVER branch. ti_v2_engine ON → v2 is authoritative: v1 not computed,
  # not persisted, not published; v2 persists (TIH engine_version='v2' + ccv) and ships the v2
  # headline over the wire. A v2 failure FAILS the stage (Sidekiq retry) — unlike shadow.
  describe "TI v2 cutover branch (ti_v2_engine ON)" do
    before do
      allow(Flipper).to receive(:enabled?).with(:ti_v2_engine).and_return(true)
    end

    it "persists ONLY a v2 row (no v1 row, no ErvEstimate) with ccv = engine V" do
      expect { worker.perform(stream.id) }
        .to change(TrustIndexHistory.where(engine_version: "v2"), :count).by(1)
        .and change(TrustIndexHistory.where(engine_version: "v1"), :count).by(0)
        .and change(ErvEstimate, :count).by(0)
      row = TrustIndexHistory.where(engine_version: "v2").last
      expect(row.trust_index_score).to be_nil
      expect(row.band_color).to be_present
    end

    it "publishes the v2 headline contract (erv/band/authenticity), not the v1 legacy shape" do
      published = []
      fake_redis = instance_double(Redis)
      allow(fake_redis).to receive(:set).and_return(true)
      allow(fake_redis).to receive(:publish) { |_ch, payload| published << payload }
      allow(worker).to receive(:redis).and_return(fake_redis)

      worker.perform(stream.id)

      expect(published.size).to eq(1)
      parsed = JSON.parse(published.first)
      expect(parsed).to include("engine_version" => "v2")
      expect(parsed.keys).to include("erv", "erv_interval", "authenticity", "band", "reason_codes")
      expect(parsed.keys).not_to include("ti_score", "classification")
    end

    it "keeps the calibration-observables stream alive (SCW shadow line, v1 fields null)" do
      allow(Rails.logger).to receive(:info)
      worker.perform(stream.id)
      expect(Rails.logger).to have_received(:info).with(/SCW shadow.*"v1_ti":null/)
    end

    it "a v2 failure FAILS the stage (Sidekiq retry semantics — no silent swallow like shadow)" do
      allow(TrustIndex::V2::Engine).to receive(:compute).and_raise(StandardError, "v2 boom")
      expect { worker.perform(stream.id) }.to raise_error(StandardError, /v2 boom/)
      expect(TrustIndexHistory.where(engine_version: "v2").count).to eq(0)
    end
  end

  describe "P1 windowed-shadow accrual (BUG-A flip-path)" do
    before { allow(Flipper).to receive(:enabled?).with(:ti_v2_engine).and_return(true) }

    it "windowed_shadow_due? is false when ti_v2_cowindowed_shadow is OFF (byte-identical, no accrual)" do
      expect(worker.send(:windowed_shadow_due?, stream)).to be(false)
    end

    it "windowed_shadow_due? is false when duty <= 0 (kill-switch via CalibrationConstant)" do
      allow(Flipper).to receive(:enabled?).with(:ti_v2_cowindowed_shadow).and_return(true)
      allow(CalibrationConstant).to receive(:value_for).with("cowindowed_shadow_duty", fallback: 4).and_return(0)
      expect(worker.send(:windowed_shadow_due?, stream)).to be(false)
    end

    it "when the flag is ON + due, emits a v2_rho_conv=windowed shadow line (accrues for the P2 re-seed)" do
      stream.ccv_snapshots.create!(ccv_count: 500, timestamp: 1.minute.ago) # V>0 so the engine isn't the GREY offline short-circuit (which nils rho_convention)
      allow(Flipper).to receive(:enabled?).with(:ti_v2_cowindowed_shadow).and_return(true)
      allow(worker).to receive(:windowed_shadow_due?).and_return(true)
      allow(TrustIndex::ContextBuilder).to receive(:windowed_inputs).and_return([ Set.new(%w[u1 u2]), 400 ])
      allow(Rails.logger).to receive(:info)
      # verdict-neutral: the windowed accrual persists NOTHING — exactly the one cutover verdict row lands.
      expect { worker.perform(stream.id) }.to change(TrustIndexHistory.where(engine_version: "v2"), :count).by(1)
      expect(Rails.logger).to have_received(:info).with(/SCW shadow.*"v2_rho_conv":"windowed"/)
    end

    it "no-op (no windowed line) when the windowed CCV window is empty (v_w nil — no half-window)" do
      allow(Flipper).to receive(:enabled?).with(:ti_v2_cowindowed_shadow).and_return(true)
      allow(worker).to receive(:windowed_shadow_due?).and_return(true)
      allow(TrustIndex::ContextBuilder).to receive(:windowed_inputs).and_return([ nil, nil ])
      allow(Rails.logger).to receive(:info)
      worker.perform(stream.id)
      expect(Rails.logger).not_to have_received(:info).with(/"v2_rho_conv":"windowed"/)
    end

    it "PR-i4: when ti_v2_ie_shadow is ON + windowed due, emits a SEPARATE SCW ievt magnitude line (honest-corpus accrual)" do
      stream.ccv_snapshots.create!(ccv_count: 500, timestamp: 1.minute.ago)
      allow(Flipper).to receive(:enabled?).with(:ti_v2_cowindowed_shadow).and_return(true)
      allow(Flipper).to receive(:enabled?).with(:ti_v2_ie_shadow).and_return(true)
      allow(worker).to receive(:windowed_shadow_due?).and_return(true)
      allow(TrustIndex::ContextBuilder).to receive(:windowed_inputs).and_return([ Set.new(%w[u1 u2]), 400 ])
      allow(Rails.logger).to receive(:info)
      worker.perform(stream.id)
      expect(Rails.logger).to have_received(:info).with(/SCW ievt.*"rho_conv":"windowed"/)
    end

    it "PR-i4: NO SCW ievt line when ti_v2_ie_shadow is OFF (zero added cost, dormant)" do
      stream.ccv_snapshots.create!(ccv_count: 500, timestamp: 1.minute.ago)
      allow(Flipper).to receive(:enabled?).with(:ti_v2_cowindowed_shadow).and_return(true)
      # ti_v2_ie_shadow falls through to the general `enabled? → false` stub (before block)
      allow(worker).to receive(:windowed_shadow_due?).and_return(true)
      allow(TrustIndex::ContextBuilder).to receive(:windowed_inputs).and_return([ Set.new(%w[u1 u2]), 400 ])
      allow(Rails.logger).to receive(:info)
      worker.perform(stream.id)
      expect(Rails.logger).not_to have_received(:info).with(/SCW ievt/)
    end
  end

  # TASK-039 FR-019: enqueue Trends::AnomalyAttributionWorker per created anomaly ID
  it "enqueues Trends::AnomalyAttributionWorker за каждую созданную anomaly" do
    anomaly_ids = [ SecureRandom.uuid, SecureRandom.uuid ]
    allow(TrustIndex::Signals::AnomalyAlerter).to receive(:check).and_return(anomaly_ids)
    allow(Trends::AnomalyAttributionWorker).to receive(:perform_async)

    worker.perform(stream.id)

    anomaly_ids.each do |id|
      expect(Trends::AnomalyAttributionWorker).to have_received(:perform_async).with(id)
    end
  end

  # Phase 2 G telemetry (2026-06-03): each pipeline stage MUST emit a tagged
  # ActiveSupport::Notifications event. Subscriber chain (Sentry breadcrumbs,
  # future Prometheus exporter) depends on these. Regression guard against the
  # «probe ONE function ≠ end-to-end verified» pattern — if a stage is silently
  # dropped from instrumentation, telemetry blind-spot reappears.
  describe "pipeline stage instrumentation (Phase 2 G)" do
    it "emits an AS::N event for every PIPELINE_STAGES entry" do
      observed_events = []
      subscriber = ActiveSupport::Notifications.subscribe(/^scw\./) do |name, _start, _finish, _id, payload|
        observed_events << [ name, payload[:stream_id] ]
      end

      worker.perform(stream.id)

      ActiveSupport::Notifications.unsubscribe(subscriber)

      observed_names = observed_events.map(&:first)
      described_class::PIPELINE_STAGES.each do |stage|
        expect(observed_names).to include("scw.#{stage}"),
          "expected SCW stage 'scw.#{stage}' to be instrumented — telemetry blind-spot " \
          "if missing (per memory/feedback_telemetry_first_diagnostic.md)"
      end

      observed_stream_ids = observed_events.map(&:last).uniq
      expect(observed_stream_ids).to eq([ stream.id ]),
        "every stage event must tag stream_id for downstream filtering"
    end

    it "tags Sentry scope + re-raises when a stage raises (preserves Sidekiq retry)" do
      skip "sentry-ruby not loaded in test env" unless defined?(Sentry)

      allow(TrustIndex::Signals::Registry).to receive(:compute_all).and_raise(RuntimeError, "boom")

      scope_double = instance_double(Sentry::Scope)
      allow(scope_double).to receive(:set_tags)
      allow(scope_double).to receive(:set_fingerprint)
      allow(Sentry).to receive(:with_scope).and_yield(scope_double)
      allow(Sentry).to receive(:capture_exception)
      allow(Sentry).to receive(:add_breadcrumb)

      expect { worker.perform(stream.id) }.to raise_error(RuntimeError, "boom")

      expect(scope_double).to have_received(:set_tags)
        .with(hash_including(scw_stage: "signals_compute", stream_id: stream.id))
      expect(scope_double).to have_received(:set_fingerprint)
        .with([ "scw", "signals_compute", "RuntimeError" ])
      expect(Sentry).to have_received(:capture_exception)
    end
  end
end
