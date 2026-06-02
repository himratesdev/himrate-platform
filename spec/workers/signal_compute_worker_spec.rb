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

  it "logs info with TI score and duration" do
    expect(Rails.logger).to receive(:info).with(/SignalComputeWorker: stream.*TI=/)
    worker.perform(stream.id)
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
