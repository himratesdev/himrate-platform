# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ml::Features::MaturitySignals do
  include ActiveSupport::Testing::TimeHelpers

  let(:channel) { create(:channel) }
  let(:stream) { create(:stream, channel: channel) }
  let(:maturity) { described_class.new(stream) }

  describe "#call (cold-start — no twitch_created_at, no prior streams)" do
    it "account_age_days_capped nil + reason when twitch_created_at missing" do
      expect(channel.twitch_created_at).to be_nil
      result = maturity.call
      expect(result[:account_age_days_capped]).to be_nil
      expect(maturity.insufficient_data_reasons[:account_age_days_capped]).to eq("no_twitch_created_at_yet")
    end

    it "total_streams_capped = 1 when only the current ended stream exists" do
      stream.update!(ended_at: Time.current)
      expect(maturity.call[:total_streams_capped]).to eq(1)
    end

    it "total_hours_capped = 0 when no completed streams (started but ongoing)" do
      stream.update!(ended_at: nil)
      expect(maturity.call[:total_hours_capped]).to eq(0.0)
    end
  end

  describe "#call (happy-path — established channel)" do
    # CR-255 Nit-6: pin time so `eq(365.0)` cap check stays stable regardless of when the
    # CI clock ticks. `twitch_created_at` set to 700d before frozen "now" → age = 700d,
    # cap of 365 fires deterministically.
    let(:now) { Time.zone.parse("2026-06-02T12:00:00Z") }

    before do
      travel_to(now)
      channel.update!(twitch_created_at: 700.days.ago)
      # 5 completed prior streams of 2h each + current 1h stream.
      5.times do |i|
        create(:stream, channel: channel,
               started_at: (10 + i).days.ago, ended_at: (10 + i).days.ago + 2.hours)
      end
      stream.update!(started_at: 1.hour.ago, ended_at: Time.current)
    end

    after { travel_back }

    it "account_age_days_capped capped at 365 (channel >1yr old)" do
      expect(maturity.call[:account_age_days_capped]).to eq(365.0)
    end

    it "total_streams_capped = 6 (5 priors + current)" do
      expect(maturity.call[:total_streams_capped]).to eq(6)
    end

    it "total_hours_capped accurately sums durations" do
      # 5 * 2h + 1 * 1h = 11h
      expect(maturity.call[:total_hours_capped]).to be_within(0.01).of(11.0)
    end
  end

  describe "#call (young channel under 1 year)" do
    before do
      channel.update!(twitch_created_at: 100.days.ago)
    end

    it "account_age_days_capped returns actual age (not capped)" do
      age = maturity.call[:account_age_days_capped]
      expect(age).to be_within(0.5).of(100.0)
      expect(age).to be < described_class::AGE_CAP_DAYS
    end
  end

  describe "#call (streams cap saturation)" do
    before do
      # 250 completed streams of 1 min each — exceeds STREAMS_CAP=200.
      # CR-256 P1: all prior streams anchored BEFORE stream.ended_at so upper-bound filter
      # includes them. Without this shift, half of the 250 would be after stream.ended_at
      # (factory default 1.hour.ago) and excluded.
      250.times do |i|
        create(:stream, channel: channel,
               started_at: stream.ended_at - (i + 2).minutes,
               ended_at: stream.ended_at - (i + 1).minutes)
      end
    end

    it "total_streams_capped saturates at 200" do
      # 250 priors + current `stream` (also ended) = 251, capped at 200.
      expect(maturity.call[:total_streams_capped]).to eq(200)
    end
  end

  describe "#call (hours cap saturation)" do
    before do
      # 50 streams of 24h each = 1200 hours, exceeds HOURS_CAP=1000.
      # CR-256 P1: anchor before stream.ended_at; spread streams in the 200d window pre-anchor.
      50.times do |i|
        start_at = stream.ended_at - (200 + i).days
        create(:stream, channel: channel, started_at: start_at, ended_at: start_at + 24.hours)
      end
    end

    it "total_hours_capped saturates at 1000" do
      expect(maturity.call[:total_hours_capped]).to eq(1000.0)
    end
  end

  describe "#call (in-flight stream excluded from total_streams / total_hours)" do
    before do
      channel.update!(twitch_created_at: 200.days.ago)
      # 3 completed streams. CR-256 P1: anchor against stream.started_at (= extraction_anchor
      # fallback for in-flight streams). Without shift, fixtures pre-Time.current would still
      # be excluded because extraction_anchor falls back to started_at = 3.hours.ago, and
      # `.days.ago` snapshots are way after that.
      3.times do |i|
        create(:stream, channel: channel,
               started_at: stream.started_at - (10 + i).days,
               ended_at: stream.started_at - ((10 + i).days - 1.hour))
      end
      # `stream` itself has ended_at=1.hour.ago by default (factory). Reset it to in-flight.
      stream.update!(ended_at: nil)
    end

    it "in-flight stream excluded from total_streams_capped" do
      expect(maturity.call[:total_streams_capped]).to eq(3)
    end

    it "in-flight stream excluded from total_hours_capped" do
      expect(maturity.call[:total_hours_capped]).to be_within(0.01).of(3.0)
    end
  end
end
