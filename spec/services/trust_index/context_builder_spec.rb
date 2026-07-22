# frozen_string_literal: true

require "rails_helper"

RSpec.describe TrustIndex::ContextBuilder do
  let(:channel) { Channel.create!(twitch_id: "cb_ch", login: "cb_channel", display_name: "CB") }
  let(:stream) { Stream.create!(channel: channel, started_at: 1.hour.ago, game_name: "Just Chatting") }

  # build() now checks two flags (:cross_channel_digest + T1-057 :temporal_cross_channel). Default to
  # the real (memory-adapter) Flipper for any flag the example doesn't explicitly stub, so a partial
  # stub on one flag doesn't raise unexpected-arguments when build() checks the other.
  before { allow(Flipper).to receive(:enabled?).and_call_original }

  it "returns Hash with all expected keys" do
    context = described_class.build(stream)

    expected_keys = %i[
      latest_ccv stream_chatters ccv_series_15min ccv_series_30min ccv_series_10min
      chat_rate_10min chat_username_counts_5min unique_chatters_60min
      chatters_present_total bot_scores
      channel_protection_config cross_channel_counts temporal_cross_channel_flags
      raids recent_raids category stream_duration_min
    ]
    expect(context.keys).to match_array(expected_keys)
  end

  describe "raid-window robustness (pre-flip corroborator safety)" do
    it "G2: the raid gate spans 10min (matches the CcvChatCorrelation divergence window), not 5min" do
      create(:raid_attribution, stream: stream, timestamp: 7.minutes.ago) # in the old 5-10min shadow
      expect(described_class.build(stream)[:recent_raids].size).to eq(1) # still suppresses (was dropped by the 5min gate)
    end

    it "G2: raids older than the 10min window are excluded" do
      create(:raid_attribution, stream: stream, timestamp: 12.minutes.ago)
      expect(described_class.build(stream)[:recent_raids]).to be_empty
    end

    it "G3: a raid-query error fails CLOSED — a non-bot sentinel so raid_window suppresses (not fail-open)" do
      allow(stream).to receive(:raid_attributions).and_raise(ActiveRecord::StatementInvalid.new("boom"))
      raids = described_class.send(:fetch_recent_raids, stream)
      expect(raids).not_to be_empty                  # raid_window#any? → true → suppress fraud escalation
      expect(raids.first[:is_bot_raid]).to be(false)  # never manufactures a bot-raid penalty
      expect(raids.first[:error_sentinel]).to be(true)
    end
  end

  # BUG-251.30: chatters_present_total sourced from ChattersSnapshot.chatters_present_total
  # (populated by StreamMonitorWorker#poll_tier1 via Twitch::GqlClient#community_tab).
  describe "chatters_present_total" do
    it "returns latest non-nil chatters_present_total from ChattersSnapshot" do
      ChattersSnapshot.create!(
        stream: stream, timestamp: 5.minutes.ago,
        unique_chatters_count: 0, total_messages_count: 0,
        chatters_present_total: 90
      )
      ChattersSnapshot.create!(
        stream: stream, timestamp: 1.minute.ago,
        unique_chatters_count: 0, total_messages_count: 0,
        chatters_present_total: 106
      )

      context = described_class.build(stream)
      expect(context[:chatters_present_total]).to eq(106)
    end

    it "skips snapshots with nil chatters_present_total (pre-deploy rows)" do
      ChattersSnapshot.create!(
        stream: stream, timestamp: 5.minutes.ago,
        unique_chatters_count: 12, total_messages_count: 40,
        chatters_present_total: nil
      )
      ChattersSnapshot.create!(
        stream: stream, timestamp: 1.minute.ago,
        unique_chatters_count: 14, total_messages_count: 50,
        chatters_present_total: 87
      )

      context = described_class.build(stream)
      expect(context[:chatters_present_total]).to eq(87)
    end

    it "returns nil when no snapshots have presence column populated" do
      ChattersSnapshot.create!(
        stream: stream, timestamp: 1.minute.ago,
        unique_chatters_count: 10, total_messages_count: 30,
        chatters_present_total: nil
      )

      context = described_class.build(stream)
      expect(context[:chatters_present_total]).to be_nil
    end
  end

  it "fetches latest CCV from snapshots" do
    CcvSnapshot.create!(stream: stream, timestamp: 5.minutes.ago, ccv_count: 500)
    CcvSnapshot.create!(stream: stream, timestamp: 1.minute.ago, ccv_count: 800)

    context = described_class.build(stream)
    expect(context[:latest_ccv]).to eq(800)
  end

  it "builds CCV series limited by time window" do
    20.times { |i| CcvSnapshot.create!(stream: stream, timestamp: (20 - i).minutes.ago, ccv_count: 500 + i) }

    context = described_class.build(stream)
    expect(context[:ccv_series_15min].size).to be <= 15
    expect(context[:ccv_series_30min].size).to eq(20)
  end

  it "resolves category from game_name" do
    context = described_class.build(stream)
    expect(context[:category]).to eq("just_chatting")
  end

  it "returns nils gracefully when no data" do
    context = described_class.build(stream)
    expect(context[:latest_ccv]).to be_nil
    expect(context[:bot_scores]).to eq([])
    expect(context[:raids]).to eq([])
  end

  it "calculates stream duration in minutes" do
    context = described_class.build(stream)
    expect(context[:stream_duration_min]).to be_between(59, 61)
  end

  # BUG-SCW-CROSS-CHANNEL (2026-06-02): fetch_cross_channel has two paths.
  #   - Flipper OFF (default): legacy CH `cross_channel` query (24h scan — preserved as fallback).
  #   - Flipper ON: CH `stream_chatters` (pick 500) + CrossChannelDigest.bulk_lookup (PG, ~5ms).
  describe "fetch_cross_channel (BUG-SCW-CROSS-CHANNEL digest path)" do
    context "when Flipper :cross_channel_digest is OFF" do
      before { allow(Flipper).to receive(:enabled?).with(:cross_channel_digest).and_return(false) }

      it "delegates to the legacy CH cross_channel scan" do
        expect(Clickhouse::ChatQueries).to receive(:cross_channel)
          .with(stream, instance_of(ActiveSupport::TimeWithZone))
          .and_return("alice" => 3)
        expect(Clickhouse::ChatQueries).not_to receive(:stream_chatters)
        expect(CrossChannelDigest).not_to receive(:bulk_lookup)

        context = described_class.build(stream)
        expect(context[:cross_channel_counts]).to eq("alice" => 3)
      end
    end

    context "when Flipper :cross_channel_digest is ON" do
      before { allow(Flipper).to receive(:enabled?).with(:cross_channel_digest).and_return(true) }

      it "uses CH stream_chatters + PG digest fetch_with_baseline (no 24h CH scan)" do
        CrossChannelDigest.upsert_all([
          { username: "alice", distinct_channels_24h: 4, refreshed_at: Time.current },
          { username: "bob",   distinct_channels_24h: 2, refreshed_at: Time.current }
        ], unique_by: :username)

        expect(Clickhouse::ChatQueries).to receive(:stream_chatters).with(stream).and_return(%w[alice bob])
        expect(Clickhouse::ChatQueries).not_to receive(:cross_channel)

        context = described_class.build(stream)
        expect(context[:cross_channel_counts]).to eq("alice" => 4, "bob" => 2)
      end

      # CR-258 M1: ensure the digest path returns 1 for single-channel chatters absent from
      # the digest (HAVING > 1 filter at write time) so the signal's `Hash#size` denominator
      # stays equal to the chatter count, preserving legacy semantics.
      it "post-fills absent (single-channel) chatters with 1 to preserve signal denominator" do
        CrossChannelDigest.upsert_all([
          { username: "alice", distinct_channels_24h: 5, refreshed_at: Time.current }
        ], unique_by: :username)

        expect(Clickhouse::ChatQueries).to receive(:stream_chatters).with(stream).and_return(%w[alice newbie ghost])

        context = described_class.build(stream)
        expect(context[:cross_channel_counts]).to eq("alice" => 5, "newbie" => 1, "ghost" => 1)
        expect(context[:cross_channel_counts].size).to eq(3) # denominator stays stable
      end

      it "returns {} when CH returns no chatters (no PG lookup attempted)" do
        expect(Clickhouse::ChatQueries).to receive(:stream_chatters).with(stream).and_return([])
        expect(CrossChannelDigest).not_to receive(:fetch_with_baseline)

        context = described_class.build(stream)
        expect(context[:cross_channel_counts]).to eq({})
      end

      it "returns {} (and logs) when the PG lookup raises StatementInvalid (graceful fallback)" do
        allow(Clickhouse::ChatQueries).to receive(:stream_chatters).and_return(%w[alice])
        allow(CrossChannelDigest).to receive(:fetch_with_baseline).and_raise(ActiveRecord::StatementInvalid.new("boom"))
        expect(Rails.logger).to receive(:warn).with(/cross_channel digest lookup failed/)

        context = described_class.build(stream)
        expect(context[:cross_channel_counts]).to eq({})
      end
    end
  end
end
