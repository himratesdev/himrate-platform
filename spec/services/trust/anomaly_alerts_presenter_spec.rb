# frozen_string_literal: true

require "rails_helper"

RSpec.describe Trust::AnomalyAlertsPresenter do
  let(:channel) { Channel.create!(twitch_id: "ap_ch", login: "ap_channel", display_name: "AP") }
  let(:source_channel) do
    Channel.create!(twitch_id: "raid_src", login: "raidersrc", display_name: "RaiderSrc")
  end
  let(:live_stream) do
    Stream.create!(channel: channel, started_at: 1.hour.ago, ended_at: nil, game_name: "Just Chatting")
  end
  let(:presenter) { described_class.new(channel: channel) }

  before do
    # Seed chatter_ccv_ratio baselines (matching Phase A migration)
    SignalConfiguration.find_or_create_by!(
      signal_type: "chatter_ccv_ratio", category: "Just Chatting", param_name: "baseline_min"
    ) { |c| c.param_value = 75 }
    SignalConfiguration.find_or_create_by!(
      signal_type: "chatter_ccv_ratio", category: "Just Chatting", param_name: "baseline_max"
    ) { |c| c.param_value = 90 }
  end

  def make_anomaly(type:, details: {}, timestamp: 1.minute.ago)
    Anomaly.create!(
      stream: live_stream,
      timestamp: timestamp,
      anomaly_type: type,
      confidence: 1.0,
      details: details
    )
  end

  describe "#call" do
    it "returns [] when канал не имеет live stream" do
      Stream.create!(channel: channel, started_at: 2.hours.ago, ended_at: 1.hour.ago)
      expect(presenter.call).to eq([])
    end

    it "returns [] when no anomalies/raids existed" do
      live_stream
      expect(presenter.call).to eq([])
    end

    context "ccv_spike alert (FR-009)" do
      it "maps ccv_step_function anomaly → ccv_spike yellow при signal_value 1.0..2.0" do
        live_stream
        make_anomaly(type: "ccv_step_function", details: { "signal_value" => 1.5 })

        result = presenter.call
        expect(result.size).to eq(1)
        alert = result.first
        expect(alert[:type]).to eq("ccv_spike")
        expect(alert[:severity]).to eq("yellow")
        expect(alert[:value]).to eq(1.5)
        expect(alert[:threshold]).to eq(1.0)
      end

      it "maps ccv_step_function → ccv_spike red при signal_value >= 2.0" do
        live_stream
        make_anomaly(type: "ccv_step_function", details: { "signal_value" => 2.5 })

        alert = presenter.call.first
        expect(alert[:severity]).to eq("red")
        expect(alert[:threshold]).to eq(2.0)
      end

      it "maps viewbot_spike → ccv_spike (alternative source)" do
        live_stream
        make_anomaly(type: "viewbot_spike", details: { "signal_value" => 1.5 })

        expect(presenter.call.first[:type]).to eq("ccv_spike")
      end
    end

    context "confirmed_raid alert (FR-010)" do
      it "reads raid_attributions WHERE is_bot_raid=false" do
        live_stream
        RaidAttribution.create!(
          stream: live_stream, source_channel: source_channel,
          timestamp: 2.minutes.ago, raid_viewers_count: 150, is_bot_raid: false
        )

        result = presenter.call
        expect(result.size).to eq(1)
        alert = result.first
        expect(alert[:type]).to eq("confirmed_raid")
        expect(alert[:severity]).to eq("info")
        expect(alert[:value]).to eq(150)
        expect(alert[:metadata][:raider_name]).to eq("RaiderSrc")
        expect(alert[:metadata][:source_channel_id]).to eq(source_channel.id)
      end

      it "skips bot raids (is_bot_raid=true)" do
        live_stream
        RaidAttribution.create!(
          stream: live_stream, source_channel: source_channel,
          timestamp: 2.minutes.ago, raid_viewers_count: 150, is_bot_raid: true
        )
        expect(presenter.call).to eq([])
      end
    end

    context "ccv_spike suppression by recent raid (FR-011, BR-021, EC-17)" do
      it "suppresses ccv_spike когда confirmed_raid arrived в 2min ДО spike" do
        live_stream
        RaidAttribution.create!(
          stream: live_stream, source_channel: source_channel,
          timestamp: 90.seconds.ago, raid_viewers_count: 200, is_bot_raid: false
        )
        make_anomaly(type: "ccv_step_function", details: { "signal_value" => 1.5 }, timestamp: 30.seconds.ago)

        result = presenter.call
        types = result.map { |a| a[:type] }
        expect(types).to include("confirmed_raid")
        expect(types).not_to include("ccv_spike")
      end

      it "does NOT suppress ccv_spike когда raid > 2min ago" do
        live_stream
        RaidAttribution.create!(
          stream: live_stream, source_channel: source_channel,
          timestamp: 4.minutes.ago, raid_viewers_count: 200, is_bot_raid: false
        )
        make_anomaly(type: "ccv_step_function", details: { "signal_value" => 1.5 }, timestamp: 30.seconds.ago)

        types = presenter.call.map { |a| a[:type] }
        expect(types).to include("ccv_spike", "confirmed_raid")
      end
    end

    context "anomaly_wave alert (FR-009, BR-007 — legal-safe naming)" do
      it "maps anomaly_wave → anomaly_wave red severity" do
        live_stream
        make_anomaly(type: "anomaly_wave", details: { "signal_value" => 0.85, "accounts_count" => 60 })

        alert = presenter.call.first
        expect(alert[:type]).to eq("anomaly_wave")
        expect(alert[:severity]).to eq("red")
      end
    end

    context "ti_drop alert (FR-014, BR-008)" do
      it "maps ti_drop anomaly → red alert with delta metadata" do
        live_stream
        make_anomaly(type: "ti_drop", details: {
                       "delta_pts" => 22.5, "from_score" => 90.0, "to_score" => 67.5,
                       "window_minutes" => 30
                     })

        alert = presenter.call.first
        expect(alert[:type]).to eq("ti_drop")
        expect(alert[:severity]).to eq("red")
        expect(alert[:value]).to eq(22.5)
        expect(alert[:window_minutes]).to eq(30)
        expect(alert[:metadata][:from_score]).to eq(90.0)
        expect(alert[:metadata][:to_score]).to eq(67.5)
      end
    end

    context "chatter_to_ccv_anomaly with category baseline lookup (FR-012, BR-009/014)" do
      it "yellow severity при value < baseline_min × 0.5 (Just Chatting baseline 75)" do
        live_stream  # game_name: "Just Chatting", baseline_min=75 → yellow если < 37.5
        make_anomaly(type: "chatter_ccv_ratio", details: { "signal_value" => 35 })

        alert = presenter.call.first
        expect(alert[:type]).to eq("chatter_to_ccv_anomaly")
        expect(alert[:severity]).to eq("yellow")
        expect(alert[:metadata][:category]).to eq("Just Chatting")
        expect(alert[:metadata][:baseline_min]).to eq(75)
      end

      it "red severity при value < baseline_min × 0.3 (75 × 0.3 = 22.5)" do
        live_stream
        make_anomaly(type: "chatter_ccv_ratio", details: { "signal_value" => 20 })

        expect(presenter.call.first[:severity]).to eq("red")
      end

      it "не presents если value >= baseline_min × 0.5 (above threshold)" do
        live_stream
        make_anomaly(type: "chatter_ccv_ratio", details: { "signal_value" => 50 })

        expect(presenter.call).to eq([])
      end

      it "ASMR alias к Music category (ADR-085 D-1 baseline storage)" do
        SignalConfiguration.find_or_create_by!(
          signal_type: "chatter_ccv_ratio", category: "Music", param_name: "baseline_min"
        ) { |c| c.param_value = 40 }
        SignalConfiguration.find_or_create_by!(
          signal_type: "chatter_ccv_ratio", category: "Music", param_name: "baseline_max"
        ) { |c| c.param_value = 70 }

        asmr_stream = Stream.create!(channel: channel, started_at: 1.hour.ago, ended_at: nil, game_name: "ASMR")
        # Replace live_stream
        live_stream.update!(ended_at: 30.minutes.ago)
        Anomaly.create!(
          stream: asmr_stream, timestamp: 1.minute.ago, anomaly_type: "chatter_ccv_ratio",
          confidence: 1.0, details: { "signal_value" => 18 }  # Music baseline 40, 18 < 40*0.5=20 → yellow
        )

        alert = presenter.call.first
        expect(alert[:metadata][:category]).to eq("Music")
        expect(alert[:metadata][:baseline_min]).to eq(40)
      end

      it "uses default baseline для unknown category" do
        live_stream.update!(game_name: "Tetris99")  # not in seeds
        make_anomaly(type: "chatter_ccv_ratio", details: { "signal_value" => 30 })

        alert = presenter.call.first
        expect(alert[:metadata][:category]).to eq("Tetris99")
        expect(alert[:metadata][:baseline_min].to_i).to eq(65)  # default fallback
      end
    end

    context "chat_entropy_drop derivation via signal_metadata (FR-018, ADR-085 D-7)" do
      it "presents chat_behavior anomaly с entropy_bits < 2.0 → chat_entropy_drop red" do
        live_stream
        make_anomaly(type: "chat_behavior", details: {
                       "signal_value" => 0.6,
                       "signal_metadata" => { "entropy_bits" => 1.4, "total_chatters" => 50 }
                     })

        alert = presenter.call.first
        expect(alert[:type]).to eq("chat_entropy_drop")
        expect(alert[:severity]).to eq("red")
        expect(alert[:value]).to eq(1.4)
        expect(alert[:threshold]).to eq(2.0)
      end

      it "skips chat_behavior anomaly if entropy_bits >= 2.0 (no chat_entropy_drop)" do
        live_stream
        make_anomaly(type: "chat_behavior", details: {
                       "signal_value" => 0.6,
                       "signal_metadata" => { "entropy_bits" => 3.5 }
                     })

        expect(presenter.call).to eq([])
      end

      it "skips chat_behavior anomaly если entropy_bits отсутствует в signal_metadata" do
        live_stream
        make_anomaly(type: "chat_behavior", details: { "signal_value" => 0.6 })

        expect(presenter.call).to eq([])
      end
    end

    context "erv_divergence alert (FR-015, BR-011)" do
      it "yellow severity при delta_pct 10..20%" do
        live_stream
        make_anomaly(type: "erv_divergence", details: {
                       "delta_pct" => 15.0, "from_erv_percent" => 80, "to_erv_percent" => 68,
                       "window_minutes" => 15
                     })

        alert = presenter.call.first
        expect(alert[:severity]).to eq("yellow")
        expect(alert[:value]).to eq(15.0)
      end

      it "red severity при delta_pct >= 20%" do
        live_stream
        make_anomaly(type: "erv_divergence", details: { "delta_pct" => 25.0 })

        expect(presenter.call.first[:severity]).to eq("red")
      end
    end

    context "sort by severity (FR-013, BR-019)" do
      it "sorts red → yellow → info" do
        live_stream
        make_anomaly(type: "ti_drop", details: { "delta_pts" => 20, "from_score" => 90, "to_score" => 70 })  # red
        make_anomaly(type: "ccv_step_function", details: { "signal_value" => 1.2 })  # yellow
        RaidAttribution.create!(
          stream: live_stream, source_channel: source_channel,
          timestamp: 4.minutes.ago, raid_viewers_count: 100, is_bot_raid: false
        )  # info

        severities = presenter.call.map { |a| a[:severity] }
        expect(severities).to eq(%w[red yellow info])
      end
    end

    context "window filter (FR-009 — 5min)" do
      it "ignores anomalies > 5min ago" do
        live_stream
        make_anomaly(type: "anomaly_wave", details: { "signal_value" => 0.9 }, timestamp: 6.minutes.ago)
        expect(presenter.call).to eq([])
      end
    end

    context "PRESENTABLE_ANOMALY_TYPES filter" do
      it "ignores non-presentable anomaly types (e.g., compute_failure)" do
        live_stream
        make_anomaly(type: "compute_failure", details: { "error" => "SomeError" })
        expect(presenter.call).to eq([])
      end
    end
  end
end
