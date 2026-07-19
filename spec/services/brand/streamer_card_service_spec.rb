# frozen_string_literal: true

require "rails_helper"

RSpec.describe Brand::StreamerCardService do
  let!(:channel) { create(:channel, login: "streamer", display_name: "Streamer") }

  def payload_for(login)
    described_class.new(login: login).call
  end

  it "returns CHANNEL_NOT_FOUND for an unknown login" do
    result = payload_for("nope")
    expect(result.ok).to be(false)
    expect(result.error).to eq("CHANNEL_NOT_FOUND")
  end

  it "resolves login case-insensitively and trims" do
    channel
    expect(payload_for("  STREAMER ").ok).to be(true)
  end

  describe "layer1 real-audience (30-day track record)" do
    it "derives real viewers from ccv_avg × erv% (botted_fraction is NULL in prod)" do
      2.times { create(:trends_daily_aggregate, channel: channel, ccv_avg: 10_000, erv_avg_percent: 80.0, ccv_peak: 14_000, streams_count: 2) }
      l1 = payload_for("streamer").payload[:layer1_real_audience]

      expect(l1[:available]).to be(true)
      expect(l1[:shown_avg_viewers]).to eq(10_000)
      expect(l1[:real_avg_viewers]).to eq(8_000) # 10000 * 0.80
      expect(l1[:real_pct]).to eq(80.0)
      expect(l1[:bot_correction_pct]).to eq(-20.0)
      expect(l1[:filtered_est]).to eq(2_000)
      expect(l1[:peak_real]).to eq(11_200) # 14000 * 0.80
      expect(l1[:window][:streams_count]).to eq(4)
      expect(l1[:basis]).to eq("trends_daily_aggregate_30d")
    end

    it "returns available:false (never zero-as-data) for an empty window" do
      l1 = payload_for("streamer").payload[:layer1_real_audience]
      expect(l1).to eq({ available: false, reason: "insufficient_window" })
    end

    it "ignores aggregate rows outside the 30-day window" do
      create(:trends_daily_aggregate, channel: channel, date: 40.days.ago.to_date, ccv_avg: 999, erv_avg_percent: 50.0)
      l1 = payload_for("streamer").payload[:layer1_real_audience]
      expect(l1[:available]).to be(false)
    end
  end

  describe "layer2 authenticity" do
    it "exposes only present signals + real overall classification (no fabricated verdict)" do
      create(:trust_index_history, channel: channel, classification: "trusted", trust_index_score: 88.0,
                                   signal_breakdown: {
                                     "auth_ratio" => { "value" => 1.0, "weight" => 0.14, "confidence" => 1.0, "contribution" => 0.14 },
                                     "chatter_ccv_ratio" => { "value" => 0.12, "weight" => 0.15, "confidence" => 0.9, "contribution" => 0.02 }
                                   })
      l2 = payload_for("streamer").payload[:layer2_authenticity]

      expect(l2[:available]).to be(true)
      expect(l2[:classification]).to eq("trusted")
      expect(l2[:ti_score]).to eq(88.0)
      expect(l2[:checks_total]).to eq(2)
      auth = l2[:checks].find { |c| c[:signal] == "auth_ratio" }
      expect(auth[:value]).to eq(1.0)
      expect(auth[:label_ru]).to be_present
      expect(l2[:checks].first).not_to have_key(:status) # per-signal verdict deferred (ADR DEC-3)
    end

    it "is unavailable when there is no trust-index history" do
      expect(payload_for("streamer").payload[:layer2_authenticity]).to eq({ available: false })
    end
  end

  describe "layer3 reputation + dispute (read-only)" do
    it "surfaces the latest open dispute and hides resolved ones" do
      create(:score_dispute, channel: channel, resolution_status: "resolved", submitted_at: 2.days.ago)
      open = create(:score_dispute, channel: channel, resolution_status: "reviewing", submitted_at: 1.hour.ago)

      l3 = payload_for("streamer").payload[:layer3_reputation]
      expect(l3[:dispute][:status]).to eq("reviewing")
      expect(l3[:dispute][:dispute_id]).to eq(open.id)
    end

    it "returns nil dispute when none are open" do
      create(:score_dispute, channel: channel, resolution_status: "resolved")
      expect(payload_for("streamer").payload[:layer3_reputation][:dispute]).to be_nil
    end
  end

  describe "layer5 anomalies (Anomaly keyed by stream_id → joined through streams)" do
    before do
      Rails.cache.clear
      create(:attribution_source, :raid_organic)
    end

    it "returns anomalies for the channel within the window with top attribution" do
      stream = create(:stream, channel: channel)
      anomaly = create(:anomaly, stream: stream, anomaly_type: "organic_spike", ccv_impact: 2_400, timestamp: 2.days.ago)
      create(:anomaly_attribution, anomaly: anomaly, source: "raid_organic", confidence: 0.8)

      l5 = payload_for("streamer").payload[:layer5_anomalies]
      expect(l5.size).to eq(1)
      expect(l5.first[:type]).to eq("organic_spike")
      expect(l5.first[:ccv_impact]).to eq(2_400)
      expect(l5.first[:attribution][:source]).to eq("raid_organic")
    end

    it "excludes anomalies from other channels" do
      other = create(:stream)
      create(:anomaly, stream: other, timestamp: 1.day.ago)
      expect(payload_for("streamer").payload[:layer5_anomalies]).to eq([])
    end
  end

  it "always advertises the deferred (not-mocked) design blocks" do
    channel
    expect(payload_for("streamer").payload[:deferred]).to include(
      "traffic_source_split", "audience_geography", "social_platforms",
      "pdf_export", "add_to_campaign", "layer2_per_signal_verdict"
    )
  end
end
