# frozen_string_literal: true

require "rails_helper"

RSpec.describe CrossChannelIntelligenceWorker do
  let(:worker) { described_class.new }
  let(:ch_client) { instance_double(Clickhouse::Client) }
  let(:redis) { instance_double(Redis) }

  before do
    # Default: only the digest section enabled (preserves the original digest tests verbatim).
    # Edge/temporal describe-blocks enable their own flags. All three must be stubbed or the worker's
    # per-section Flipper checks would hit unexpected-argument errors.
    allow(Flipper).to receive(:enabled?).with(:cross_channel_digest).and_return(true)
    allow(Flipper).to receive(:enabled?).with(:cross_channel_edges).and_return(false)
    allow(Flipper).to receive(:enabled?).with(:temporal_cross_channel).and_return(false)
    allow(Clickhouse).to receive(:client).and_return(ch_client)
    allow(Sidekiq).to receive(:redis).and_yield(redis)
    allow(redis).to receive(:set).with(described_class::OVERLAP_LOCK_KEY, anything, nx: true, ex: described_class::OVERLAP_LOCK_TTL).and_return(true)
    allow(redis).to receive(:del).with(described_class::OVERLAP_LOCK_KEY).and_return(1)
  end

  describe "per-section gating" do
    it "skips entirely (no lock) when all three sections are disabled" do
      allow(Flipper).to receive(:enabled?).with(:cross_channel_digest).and_return(false)
      expect(redis).not_to receive(:set)
      expect(ch_client).not_to receive(:select)
      worker.perform
    end

    it "runs digest without touching edges/temporal when only digest is enabled" do
      allow(ch_client).to receive(:select).and_return([ { "username" => "alice", "c" => "5" } ])
      expect { worker.perform }.to change(CrossChannelDigest, :count).by(1)
      expect(CrossChannelPresence.count).to eq(0)
      expect(CrossChannelTemporalFlag.count).to eq(0)
    end
  end

  # === Section 1: digest (unchanged behavior) ====================================================
  describe "digest section" do
    it "upserts rows from the CH aggregation" do
      allow(ch_client).to receive(:select).and_return([
        { "username" => "alice", "c" => "5" },
        { "username" => "bob",   "c" => "3" }
      ])

      expect { worker.perform }.to change(CrossChannelDigest, :count).from(0).to(2)
      expect(CrossChannelDigest.find("alice").distinct_channels_24h).to eq(5)
      expect(CrossChannelDigest.find("bob").distinct_channels_24h).to eq(3)
    end

    it "updates existing rows in place (idempotent refresh)" do
      older = 2.hours.ago
      CrossChannelDigest.upsert_all([ { username: "alice", distinct_channels_24h: 1, refreshed_at: older } ], unique_by: :username)
      allow(ch_client).to receive(:select).and_return([ { "username" => "alice", "c" => "9" } ])

      worker.perform

      row = CrossChannelDigest.find("alice")
      expect(row.distinct_channels_24h).to eq(9)
      expect(row.refreshed_at).to be > older
    end

    it "prunes digest rows older than STALE_AFTER" do
      CrossChannelDigest.upsert_all([ { username: "ghost", distinct_channels_24h: 4, refreshed_at: 26.hours.ago } ], unique_by: :username)
      allow(ch_client).to receive(:select).and_return([])

      worker.perform

      expect(CrossChannelDigest.exists?("ghost")).to be false
    end

    it "skips gracefully when CH errors (no exception, no upsert)" do
      allow(ch_client).to receive(:select).and_raise(Clickhouse::QueryError.new("boom"))
      expect { worker.perform }.not_to raise_error
      expect(CrossChannelDigest.count).to eq(0)
    end

    it "batches upserts when result exceeds UPSERT_BATCH_SIZE" do
      rows = (1..described_class::UPSERT_BATCH_SIZE + 5).map { |i| { "username" => "user#{i}", "c" => "2" } }
      allow(ch_client).to receive(:select).and_return(rows)
      expect(CrossChannelDigest).to receive(:upsert_all).at_least(:twice).and_call_original

      worker.perform
      expect(CrossChannelDigest.count).to eq(described_class::UPSERT_BATCH_SIZE + 5)
    end
  end

  # === Section 2: edges (FR-A) ====================================================================
  describe "edges section" do
    let!(:channel) { create(:channel, login: "melharucos") }

    before do
      allow(Flipper).to receive(:enabled?).with(:cross_channel_digest).and_return(false)
      allow(Flipper).to receive(:enabled?).with(:cross_channel_edges).and_return(true)
    end

    # Flaky-fix (post-#323): compute_edges! prunes source='live' edges with last_seen_at < now-25h
    # IN THE SAME perform. The previous hardcoded absolute timestamps (2026-06-25 ...) went stale
    # relative to that rolling 25h window as wall-clock advanced → the just-upserted edge was pruned
    # the same cycle → count changed by 0 (deterministically red ~25h after merge, any seed). Relative
    # timestamps keep the edge inside the window at any wall-clock + any seed. UTC to match CH output.
    def fresh_edge(channel_login: "melharucos", username: "viewer1", msgs: "42")
      {
        "username" => username, "channel_login" => channel_login,
        "first_seen" => 3.hours.ago.utc.strftime("%Y-%m-%d %H:%M:%S"),
        "last_seen" => 1.hour.ago.utc.strftime("%Y-%m-%d %H:%M:%S"),
        "message_count" => msgs
      }
    end

    it "upserts edges resolved to channel_id with source='live'" do
      allow(Clickhouse::ChatQueries).to receive(:cross_channel_edges).and_return([ fresh_edge(msgs: "42") ])

      expect { worker.perform }.to change(CrossChannelPresence, :count).by(1)
      edge = CrossChannelPresence.find_by(username: "viewer1", channel_id: channel.id)
      expect(edge.source).to eq("live")
      expect(edge.message_count).to eq(42)
      expect(edge.stream_id).to be_nil
    end

    it "resolves channel_login case-insensitively (downcase guard)" do
      channel.update!(login: "MelHaRucos") # mixed-case PG login
      allow(Clickhouse::ChatQueries).to receive(:cross_channel_edges).and_return([ fresh_edge(msgs: "5") ])

      expect { worker.perform }.to change(CrossChannelPresence, :count).by(1)
    end

    it "skips edges for unmonitored/unresolved channels" do
      allow(Clickhouse::ChatQueries).to receive(:cross_channel_edges).and_return([ fresh_edge(channel_login: "ghost_channel", msgs: "5") ])

      expect { worker.perform }.not_to change(CrossChannelPresence, :count)
    end

    it "leaves prior edges intact and skips prune when CH errors (failure isolation)" do
      stale = create(:cross_channel_presence, channel: channel, source: "live", last_seen_at: 30.hours.ago)
      allow(Clickhouse::ChatQueries).to receive(:cross_channel_edges).and_raise(Clickhouse::QueryError.new("ch down"))

      expect { worker.perform }.not_to raise_error
      expect(CrossChannelPresence.exists?(stale.id)).to be true # NOT pruned
    end

    it "prunes only stale source='live' edges, never vod" do
      create(:cross_channel_presence, channel: channel, source: "live", last_seen_at: 30.hours.ago, username: "stale_live")
      create(:cross_channel_presence, channel: channel, source: "vod",  last_seen_at: 30.hours.ago, username: "old_vod")
      allow(Clickhouse::ChatQueries).to receive(:cross_channel_edges).and_return([])

      worker.perform

      expect(CrossChannelPresence.exists?(username: "stale_live")).to be false
      expect(CrossChannelPresence.exists?(username: "old_vod")).to be true
    end
  end

  # === Section 3: temporal co-occurrence (FR-B) ===================================================
  describe "temporal section" do
    before do
      allow(Flipper).to receive(:enabled?).with(:cross_channel_digest).and_return(false)
      allow(Flipper).to receive(:enabled?).with(:temporal_cross_channel).and_return(true)
    end

    def temporal_row(username, r, mc = 3)
      { "username" => username, "event_count" => r.to_s, "max_concurrent" => mc.to_s, "last_event_at" => "2026-06-25 10:00:00" }
    end

    it "classifies tiers by R (watch/flag/yellow/confirmed)" do
      allow(Clickhouse::ChatQueries).to receive(:temporal_co_occurrence).and_return([
        temporal_row("watcher", 2), temporal_row("flagged", 3),
        temporal_row("yellowy", 5), temporal_row("confirmd", 9)
      ])

      worker.perform

      expect(CrossChannelTemporalFlag.find("watcher").bot_flag_tier).to eq("watch")
      expect(CrossChannelTemporalFlag.find("flagged").bot_flag_tier).to eq("flag")
      expect(CrossChannelTemporalFlag.find("yellowy").bot_flag_tier).to eq("yellow")
      expect(CrossChannelTemporalFlag.find("confirmd").bot_flag_tier).to eq("confirmed")
    end

    it "marks allowlisted platform bots as bot_type=utility, others spam" do
      allow(Clickhouse::ChatQueries).to receive(:temporal_co_occurrence).and_return([
        temporal_row("nightbot", 200, 71), temporal_row("trafi_kroki", 9, 3)
      ])

      worker.perform

      expect(CrossChannelTemporalFlag.find("nightbot").bot_type).to eq("utility")
      expect(CrossChannelTemporalFlag.find("trafi_kroki").bot_type).to eq("spam")
    end

    it "stores R, max_concurrent and window_seconds" do
      allow(Clickhouse::ChatQueries).to receive(:temporal_co_occurrence).and_return([ temporal_row("bot1", 9, 4) ])

      worker.perform

      flag = CrossChannelTemporalFlag.find("bot1")
      expect(flag.event_count).to eq(9)
      expect(flag.max_concurrent_channels).to eq(4)
      expect(flag.window_seconds).to eq(described_class::WINDOW_SECONDS)
    end

    it "leaves prior flags intact and skips prune when CH errors (failure isolation)" do
      CrossChannelTemporalFlag.create!(username: "old", event_count: 9, max_concurrent_channels: 3,
        bot_flag_tier: "confirmed", bot_type: "spam", window_seconds: 5, refreshed_at: 30.hours.ago)
      allow(Clickhouse::ChatQueries).to receive(:temporal_co_occurrence).and_raise(Clickhouse::QueryError.new("ch down"))

      expect { worker.perform }.not_to raise_error
      expect(CrossChannelTemporalFlag.exists?("old")).to be true # NOT pruned
    end

    it "prunes temporal flags older than STALE_AFTER" do
      CrossChannelTemporalFlag.create!(username: "ghost", event_count: 9, max_concurrent_channels: 3,
        bot_flag_tier: "confirmed", bot_type: "spam", window_seconds: 5, refreshed_at: 26.hours.ago)
      allow(Clickhouse::ChatQueries).to receive(:temporal_co_occurrence).and_return([])

      worker.perform

      expect(CrossChannelTemporalFlag.exists?("ghost")).to be false
    end
  end

  # === Overlap lock (CR-258 S2 — unchanged) =======================================================
  describe "overlap lock" do
    it "skips the run entirely when the lock is held by another worker" do
      allow(redis).to receive(:set).and_return(nil)
      expect(ch_client).not_to receive(:select)
      expect(redis).not_to receive(:del)
      expect(Rails.logger).to receive(:info).with(/overlap lock held/)

      worker.perform
    end

    it "releases the lock after a successful run" do
      allow(ch_client).to receive(:select).and_return([])
      expect(redis).to receive(:del).with(described_class::OVERLAP_LOCK_KEY)
      worker.perform
    end

    it "proceeds (fail-open) when Redis is unavailable for lock acquire" do
      allow(redis).to receive(:set).and_raise(Redis::CannotConnectError.new("redis down"))
      allow(ch_client).to receive(:select).and_return([])
      expect(Rails.logger).to receive(:warn).with(/lock acquire failed/)

      worker.perform
    end
  end
end
