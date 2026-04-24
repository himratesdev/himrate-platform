# frozen_string_literal: true

require "rails_helper"

RSpec.describe Trends::VisualQa::DataSeeder do
  describe "production guard" do
    it "raises ProductionGuardTripped на Rails.env.production" do
      allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("production"))

      expect { described_class.seed(login: "vqa_test_x") }
        .to raise_error(Trends::VisualQa::DataSeeder::ProductionGuardTripped)
    end

    it "raises ProductionGuardTripped при clear в production" do
      allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("production"))

      expect { described_class.clear(login: "vqa_test_x") }
        .to raise_error(Trends::VisualQa::DataSeeder::ProductionGuardTripped)
    end
  end

  describe ".seed" do
    let(:login) { "vqa_test_premium_01" }

    before do
      # Minimal SignalConfiguration rows needed для analysis services called из DailyBuilder.
      SignalConfiguration.upsert_all(
        [
          [ "trends", "discovery", "channel_age_max_days", 60 ],
          [ "trends", "discovery", "min_data_points", 7 ],
          [ "trends", "discovery", "logistic_r2_organic_min", 0.7 ],
          [ "trends", "discovery", "step_r2_burst_min", 0.9 ],
          [ "trends", "discovery", "burst_window_days_max", 3 ],
          [ "trends", "discovery", "burst_jump_min", 1000 ],
          [ "trends", "coupling", "rolling_window_days", 30 ],
          [ "trends", "coupling", "healthy_r_min", 0.7 ],
          [ "trends", "coupling", "weakening_r_min", 0.3 ],
          [ "trends", "coupling", "min_history_days", 7 ],
          [ "trends", "best_worst", "min_streams_required", 3 ]
        ].map do |sig, cat, p, v|
          { signal_type: sig, category: cat, param_name: p, param_value: v, created_at: Time.current, updated_at: Time.current }
        end,
        unique_by: %i[signal_type category param_name], on_duplicate: :skip
      )
    end

    it "creates full data chain для premium_tracked profile" do
      result = described_class.seed(login: login, profile: "premium_tracked")
      stats = result[:stats]
      channel = result[:channel]

      expect(channel.login).to eq(login)
      expect(stats[:streams]).to eq(30)
      expect(stats[:tih]).to eq(30)
      expect(stats[:tda]).to be > 0
      expect(stats[:anomalies]).to eq(3)
      # CR N-3: anomaly_attributions + follower_snapshots в stats.
      expect(stats[:anomaly_attributions]).to be >= 3 # at minimum unattributed fallback per anomaly
      expect(stats[:follower_snapshots]).to eq(30)
      expect(stats[:tier_changes]).to eq(2)
      expect(stats[:rehab_events]).to eq(0)

      seed_record = VisualQaChannelSeed.find_by(channel_id: channel.id)
      expect(seed_record.seed_profile).to eq("premium_tracked")
      expect(seed_record.schema_version).to eq(1)
    end

    it "CR S-1: full transaction rollback когда run_profile fails" do
      # Force TihHistorySeeder to raise mid-chain.
      allow(Trends::VisualQa::TihHistorySeeder).to receive(:seed).and_raise(StandardError.new("boom"))

      expect { described_class.seed(login: login, profile: "premium_tracked") }
        .to raise_error(StandardError, "boom")

      # Verify: Channel + VisualQaChannelSeed + Streams rolled back — no orphans.
      expect(Channel.find_by(login: login)).to be_nil
      expect(VisualQaChannelSeed.count).to eq(0)
      expect(Stream.count).to eq(0)
    end

    it "creates streamer_with_rehab profile с rehab event" do
      result = described_class.seed(login: login, profile: "streamer_with_rehab")
      stats = result[:stats]

      expect(stats[:streams]).to eq(30)
      expect(stats[:tier_changes]).to eq(1)
      expect(stats[:rehab_events]).to eq(1)
      expect(stats[:anomalies]).to eq(0)
    end

    it "cold_start profile: <3 streams, no TIH/TDA" do
      result = described_class.seed(login: login, profile: "cold_start")
      stats = result[:stats]

      expect(stats[:streams]).to eq(2)
      expect(stats[:tih]).to eq(0)
      expect(stats[:tda]).to eq(0)
    end

    it "is idempotent — re-run не создаёт duplicates" do
      described_class.seed(login: login, profile: "premium_tracked")
      channel = Channel.find_by(login: login)
      stream_count_first = channel.streams.count

      described_class.seed(login: login, profile: "premium_tracked")
      expect(channel.streams.count).to eq(stream_count_first) # нет duplicates per stream
      expect(VisualQaChannelSeed.where(channel_id: channel.id).count).to eq(1)
    end

    it "rejects login без 'vqa_test_' prefix (safety)" do
      expect { described_class.seed(login: "real_channel") }
        .to raise_error(Trends::VisualQa::ChannelSeeder::InvalidLogin)
    end

    it "rejects unknown profile" do
      expect { described_class.seed(login: login, profile: "unknown") }
        .to raise_error(Trends::VisualQa::DataSeeder::SeedError, /Unknown profile/)
    end
  end

  describe ".clear" do
    let(:login) { "vqa_test_teardown" }

    before do
      SignalConfiguration.upsert_all(
        [
          [ "trends", "discovery", "channel_age_max_days", 60 ],
          [ "trends", "discovery", "min_data_points", 7 ],
          [ "trends", "discovery", "logistic_r2_organic_min", 0.7 ],
          [ "trends", "discovery", "step_r2_burst_min", 0.9 ],
          [ "trends", "discovery", "burst_window_days_max", 3 ],
          [ "trends", "discovery", "burst_jump_min", 1000 ],
          [ "trends", "coupling", "rolling_window_days", 30 ],
          [ "trends", "coupling", "healthy_r_min", 0.7 ],
          [ "trends", "coupling", "weakening_r_min", 0.3 ],
          [ "trends", "coupling", "min_history_days", 7 ],
          [ "trends", "best_worst", "min_streams_required", 3 ]
        ].map do |sig, cat, p, v|
          { signal_type: sig, category: cat, param_name: p, param_value: v, created_at: Time.current, updated_at: Time.current }
        end,
        unique_by: %i[signal_type category param_name], on_duplicate: :skip
      )
    end

    it "removes full chain + metadata after seed" do
      described_class.seed(login: login, profile: "premium_tracked")
      channel_id = Channel.find_by(login: login).id

      result = described_class.clear(login: login)
      expect(result[:cleared]).to be true
      expect(Channel.where(id: channel_id)).to be_empty
      expect(VisualQaChannelSeed.where(channel_id: channel_id)).to be_empty
      expect(TrustIndexHistory.where(channel_id: channel_id)).to be_empty
      expect(TrendsDailyAggregate.where(channel_id: channel_id)).to be_empty
    end

    it "no-op когда channel не существует" do
      result = described_class.clear(login: "vqa_test_nonexistent")
      expect(result[:cleared]).to be false
      expect(result[:reason]).to eq("channel_not_found")
    end

    # CR N-5: status coverage
    describe ".status" do
      it "refuses invalid login prefix (consistent с seed/clear)" do
        expect { described_class.new(login: "real_channel", profile: nil).status }
          .to raise_error(Trends::VisualQa::ChannelSeeder::InvalidLogin)
      end

      it "refuses в production env" do
        allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("production"))
        expect { described_class.new(login: "vqa_test_status_x", profile: nil).status }
          .to raise_error(Trends::VisualQa::DataSeeder::ProductionGuardTripped)
      end

      it "returns channel_not_found когда no match" do
        result = described_class.new(login: "vqa_test_status_missing", profile: nil).status
        expect(result[:seeded]).to be false
        expect(result[:reason]).to eq("channel_not_found")
      end

      it "returns seeded metadata + live_counts after seed" do
        described_class.seed(login: login, profile: "premium_tracked")
        result = described_class.new(login: login, profile: nil).status

        expect(result[:seeded]).to be true
        expect(result[:profile]).to eq("premium_tracked")
        expect(result[:schema_version]).to eq(1)
        expect(result[:live_counts]).to include(:streams, :tih, :tda, :anomalies, :anomaly_attributions, :follower_snapshots, :tier_changes, :rehab_events)
        expect(result[:live_counts][:streams]).to eq(30)
      end
    end

    it "refuses to clear non-VQA-seeded channels (safety)" do
      real_channel = create(:channel, login: "vqa_test_safety_check") # exists but no VisualQaChannelSeed row

      result = described_class.clear(login: "vqa_test_safety_check")
      expect(result[:cleared]).to be false
      expect(result[:reason]).to eq("not_a_vqa_seed")
      expect(Channel.find_by(id: real_channel.id)).to be_present
    end
  end
end
