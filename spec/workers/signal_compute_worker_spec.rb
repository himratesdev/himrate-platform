# frozen_string_literal: true

require "rails_helper"

RSpec.describe SignalComputeWorker do
  let(:worker) { described_class.new }
  let(:channel) { Channel.create!(twitch_id: "scw_ch", login: "scw_channel", display_name: "SCW") }
  let(:stream) { Stream.create!(channel: channel, started_at: 1.hour.ago, game_name: "Just Chatting") }

  before do
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
    %w[incident_threshold rehabilitation_streams rehabilitation_bonus_max].each_with_index do |param, i|
      SignalConfiguration.find_or_create_by!(
        signal_type: "trust_index", category: "default", param_name: param
      ) { |c| c.param_value = [ 40, 15, 15 ][i] }
    end
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
end
