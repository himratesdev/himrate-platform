# frozen_string_literal: true

require "rails_helper"

RSpec.describe Streams::LatestSummaryService do
  let(:channel) { Channel.create!(twitch_id: "lss_ch", login: "lss_channel", display_name: "LSS") }
  let(:service) { described_class.new(channel: channel) }

  # PR-A1 (EPIC SCALE ARCHITECTURE Step 2): peak_ccv / avg_ccv / duration_ms columns dropped
  # from streams. These specs construct streams with direct Stream.create! (not factory) →
  # the dropped attrs raise ActiveModel::UnknownAttributeError. Rewrite to pass only the
  # columns that survive (channel/started_at/ended_at/game_name/interrupted_at) and put
  # ccv/duration stats into the canonical PSR row.
  describe "#call" do
    it "returns :not_found when канал не имеет completed streams (FR-004)" do
      expect(service.call).to eq(:not_found)
    end

    it "ignores live streams (ended_at: nil) — only completed shown" do
      Stream.create!(channel: channel, started_at: 30.minutes.ago, ended_at: nil)
      expect(service.call).to eq(:not_found)
    end

    it "returns latest completed stream (FR-001) с full PostStreamReport data" do
      stream = Stream.create!(
        channel: channel, started_at: 6.hours.ago, ended_at: 1.hour.ago,
        game_name: "Just Chatting"
      )
      PostStreamReport.create!(
        stream: stream, ccv_peak: 5234, ccv_avg: 3650,
        erv_percent_final: 85.5, erv_final: 4200,
        duration_ms: 18_000_000, generated_at: 50.minutes.ago
      )

      result = service.call
      expect(result).to be_a(Hash)
      expect(result[:data][:session_id]).to eq(stream.id)
      expect(result[:data][:duration_seconds]).to eq(18_000)
      expect(result[:data][:duration_text]).to be_present
      expect(result[:data][:peak_viewers]).to eq(5234)  # PR-A1: PSR.ccv_peak is canonical source
      expect(result[:data][:avg_ccv]).to eq(3650)
      expect(result[:data][:erv_percent_final]).to be_within(0.1).of(85.5)
      expect(result[:data][:erv_count_final]).to eq(4200)
      expect(result[:data][:category]).to eq("Just Chatting")
      expect(result[:data][:partial]).to be(false)
      expect(result[:meta][:preliminary]).to be(false)
    end

    it "returns preliminary state когда post_stream_reports row не существует (FR-006, EC-5)" do
      # PR-A1: without PSR, Stream#current_peak_ccv / current_avg_ccv / current_duration_ms
      # fall back to CcvSnapshot aggregates. Seed snapshots so the spec sees realistic
      # preliminary numbers (was 5000 / 3500 from the dropped columns).
      stream = Stream.create!(
        channel: channel, started_at: 6.hours.ago, ended_at: 1.hour.ago,
        game_name: "Gaming"
      )
      CcvSnapshot.create!(stream: stream, timestamp: 5.hours.ago, ccv_count: 3500)
      CcvSnapshot.create!(stream: stream, timestamp: 4.hours.ago, ccv_count: 5000)
      CcvSnapshot.create!(stream: stream, timestamp: 3.hours.ago, ccv_count: 3000)
      # max = 5000, mean = (3500+5000+3000)/3 ≈ 3833 → round 3833

      result = service.call
      expect(result[:data][:peak_viewers]).to eq(5000)  # CcvSnapshot.max fallback
      expect(result[:data][:avg_ccv]).to eq(3833)        # CcvSnapshot.average rounded
      expect(result[:data][:erv_percent_final]).to be_nil
      expect(result[:data][:erv_count_final]).to be_nil
      expect(result[:meta][:preliminary]).to be(true)
    end

    it "returns partial: true когда interrupted_at установлен (FR-005, EC-2)" do
      stream = Stream.create!(
        channel: channel, started_at: 6.hours.ago, ended_at: 1.hour.ago,
        game_name: "Just Chatting", interrupted_at: 1.hour.ago
      )
      PostStreamReport.create!(stream: stream, generated_at: 50.minutes.ago)

      result = service.call
      expect(result[:data][:partial]).to be(true)
    end

    it "selects latest by ended_at DESC (EC-4 concurrent streams)" do
      Stream.create!(channel: channel, started_at: 10.hours.ago, ended_at: 8.hours.ago)
      latest = Stream.create!(channel: channel, started_at: 6.hours.ago, ended_at: 1.hour.ago)
      Stream.create!(channel: channel, started_at: 12.hours.ago, ended_at: 11.hours.ago)

      result = service.call
      expect(result[:data][:session_id]).to eq(latest.id)
    end

    it "uses includes(:post_stream_report) — no N+1 на serialization" do
      stream = Stream.create!(
        channel: channel, started_at: 6.hours.ago, ended_at: 1.hour.ago
      )
      PostStreamReport.create!(stream: stream, ccv_peak: 5000, generated_at: 50.minutes.ago)

      # Bullet would catch N+1 в development — здесь просто verify работает
      expect { service.call }.not_to raise_error
    end
  end
end
