# frozen_string_literal: true

require "rails_helper"

RSpec.describe StreamOfflineWorker do
  let(:worker) { described_class.new }
  let(:channel) { create(:channel, twitch_id: "12345", login: "teststreamer") }

  before do
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:fetch).with("REDIS_URL", anything).and_return("redis://localhost:6379/1")
  end

  let(:event_data) do
    { "broadcaster_user_id" => channel.twitch_id, "broadcaster_user_login" => channel.login }
  end

  # TC-006: Finalize Stream
  it "finalizes Stream with peak_ccv, avg_ccv, duration_ms" do
    stream = create(:stream, channel: channel, started_at: 2.hours.ago, ended_at: nil)
    create(:ccv_snapshot, stream: stream, timestamp: 1.hour.ago, ccv_count: 100)
    create(:ccv_snapshot, stream: stream, timestamp: 30.minutes.ago, ccv_count: 200)
    create(:ccv_snapshot, stream: stream, timestamp: 10.minutes.ago, ccv_count: 150)

    worker.perform(event_data)

    stream.reload
    expect(stream.ended_at).to be_present
    expect(stream.peak_ccv).to eq(200)
    expect(stream.avg_ccv).to eq(150)
    expect(stream.duration_ms).to be > 0
  end

  # TC-007: No active stream → warning
  it "logs warning if no active stream found" do
    expect(Rails.logger).to receive(:warn).with(/no active stream/)
    worker.perform(event_data)
  end

  # TASK-085 FR-020 (ADR-085 D-8a): interrupted_at heuristic detection.
  describe "interrupted_at heuristic (FR-020)" do
    it "sets interrupted_at когда last CCV snapshot > 10min ago (default threshold)" do
      stream = create(:stream, channel: channel, started_at: 2.hours.ago, ended_at: nil)
      create(:ccv_snapshot, stream: stream, timestamp: 15.minutes.ago, ccv_count: 100)

      worker.perform(event_data)

      stream.reload
      expect(stream.interrupted_at).to be_present
      expect(stream.interrupted_at).to be_within(5.seconds).of(Time.current)
    end

    it "does NOT set interrupted_at когда last CCV snapshot recent (within threshold)" do
      stream = create(:stream, channel: channel, started_at: 2.hours.ago, ended_at: nil)
      create(:ccv_snapshot, stream: stream, timestamp: 1.minute.ago, ccv_count: 100)

      worker.perform(event_data)

      stream.reload
      expect(stream.interrupted_at).to be_nil
    end

    it "does NOT set interrupted_at когда нет CCV snapshots (cannot determine)" do
      stream = create(:stream, channel: channel, started_at: 2.hours.ago, ended_at: nil)

      worker.perform(event_data)

      stream.reload
      expect(stream.interrupted_at).to be_nil
    end

    it "respects SignalConfiguration override of threshold" do
      SignalConfiguration.find_or_create_by!(
        signal_type: "stream_monitor", category: "default", param_name: "interrupted_threshold_seconds"
      ) { |c| c.param_value = 60 }

      stream = create(:stream, channel: channel, started_at: 2.hours.ago, ended_at: nil)
      create(:ccv_snapshot, stream: stream, timestamp: 90.seconds.ago, ccv_count: 100)

      worker.perform(event_data)

      stream.reload
      expect(stream.interrupted_at).to be_present
    end

    it "logs source field для forensic debugging (D-8a)" do
      stream = create(:stream, channel: channel, started_at: 2.hours.ago, ended_at: nil)
      create(:ccv_snapshot, stream: stream, timestamp: 1.minute.ago, ccv_count: 100)

      allow(Rails.logger).to receive(:info)
      worker.perform(event_data)
      expect(Rails.logger).to have_received(:info).with(/source:eventsub/).at_least(:once)
    end

    it "accepts source parameter (eventsub|timeout|manual)" do
      stream = create(:stream, channel: channel, started_at: 2.hours.ago, ended_at: nil)
      create(:ccv_snapshot, stream: stream, timestamp: 1.minute.ago, ccv_count: 100)

      allow(Rails.logger).to receive(:info)
      worker.perform(event_data, "timeout")
      expect(Rails.logger).to have_received(:info).with(/source:timeout/).at_least(:once)
    end
  end
end
