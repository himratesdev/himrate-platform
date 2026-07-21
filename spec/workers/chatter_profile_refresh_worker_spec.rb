# frozen_string_literal: true

require "rails_helper"

# PR-251.14 PR 1e-A follow-up: chat now lives in ClickHouse only (post PR #231 cutover).
# logins_to_enrich was rewritten to fetch candidates from Clickhouse::ChatQueries and then
# apply the freshness filter in Ruby against PG chatter_profiles (cross-DB JOIN is impossible).
# Specs stub the CH side and assert the Ruby filter behaviour end-to-end.
RSpec.describe ChatterProfileRefreshWorker do
  let(:worker) { described_class.new }
  let(:gql) { instance_double(Twitch::GqlClient) }

  # In-memory ledger driving Clickhouse::ChatQueries.distinct_active_chatters. Each entry is
  # { username:, at: } — the stub filters by `since` cutoff so timestamp-sensitive specs still work.
  let(:ch_chatters) { [] }
  # BUG-C: ledger driving Clickhouse::ChatQueries.chatters_on_streams (chatters on live monitored
  # streams — the fraud-priority set). Only consulted when Stream.active is non-empty.
  let(:ch_live_chatters) { [] }

  before do
    allow(Flipper).to receive(:enabled?).with(:stream_monitor).and_return(true)
    allow(Flipper).to receive(:enabled?).with(:chatter_profile_enrichment).and_return(true)
    allow(Twitch::GqlClient).to receive(:new).and_return(gql)

    allow(Clickhouse::ChatQueries).to receive(:distinct_active_chatters) do |since:, limit:|
      ch_chatters
        .select { |row| row[:at] > since }
        .map { |row| row[:username] }
        .uniq
        .first(limit.to_i)
    end
    allow(Clickhouse::ChatQueries).to receive(:chatters_on_streams) do |_stream_ids, limit:|
      ch_live_chatters.uniq.first(limit.to_i)
    end
  end

  def chat(username, ts: 10.minutes.ago)
    ch_chatters << { username: username, at: ts }
  end

  # register a chatter as present on a currently-live monitored stream (priority set)
  def live_chat(username)
    ch_live_chatters << username
  end

  def profile(login:, created_at: "2020-01-01T00:00:00Z", followers: 100)
    # TASK-251.20: profile_view_count dropped (Twitch deprecated profileViewCount).
    { id: "id_#{login}", login: login, created_at: created_at, followers_count: followers,
      follows_count: 50 }
  end

  it "skips when either flag is disabled" do
    allow(Flipper).to receive(:enabled?).with(:chatter_profile_enrichment).and_return(false)
    expect(gql).not_to receive(:batch_bot_check)
    worker.perform
  end

  it "enriches a recently-active chatter with no cached profile" do
    chat("alice")
    allow(gql).to receive(:batch_bot_check).with(logins: [ "alice" ]).and_return([ profile(login: "alice", followers: 0) ])

    expect { worker.perform }.to change(ChatterProfile, :count).by(1)

    cp = ChatterProfile.find_by(login: "alice")
    expect(cp.followers_count).to eq(0)
    expect(cp.follows_count).to eq(50)
    expect(cp.twitch_user_id).to eq("id_alice")
    expect(cp.twitch_created_at).to be_present
    expect(cp.fetched_at).to be_present
  end

  # MF-1: unresolved logins (banned/deleted OR transient GQL miss) are NOT cached — caching them
  # with null fields would feed fabricated flags into bot scoring / #11. Un-cached = retried.
  it "does NOT cache unresolved (nil) chatters" do
    chat("ghost")
    allow(gql).to receive(:batch_bot_check).with(logins: [ "ghost" ]).and_return([ nil ])

    expect { worker.perform }.not_to change(ChatterProfile, :count)
  end

  it "does NOT cache anyone when the GQL batch fails transiently (retried next run)" do
    chat("flap")
    allow(gql).to receive(:batch_bot_check).and_raise(StandardError, "GQL timeout")

    expect { worker.perform }.not_to change(ChatterProfile, :count)
  end

  it "skips chatters already cached within STALE_AFTER (Ruby NOT EXISTS filter)" do
    chat("cached")
    ChatterProfile.create!(login: "cached", fetched_at: 1.day.ago)
    expect(gql).not_to receive(:batch_bot_check)
    worker.perform
  end

  it "re-enriches stale cached chatters (fetched_at < STALE_AFTER.ago passes the filter)" do
    chat("stale")
    ChatterProfile.create!(login: "stale", followers_count: 5, fetched_at: 40.days.ago)
    allow(gql).to receive(:batch_bot_check).with(logins: [ "stale" ]).and_return([ profile(login: "stale", followers: 999) ])

    worker.perform
    expect(ChatterProfile.find_by(login: "stale").followers_count).to eq(999)
  end

  it "ignores chatters not active within LOOKBACK (CH stub respects `since` cutoff)" do
    chat("old", ts: 5.hours.ago)
    expect(gql).not_to receive(:batch_bot_check)
    worker.perform
  end

  it "is bounded by MAX_PER_RUN and batches by GQL batch size" do
    stub_const("ChatterProfileRefreshWorker::MAX_PER_RUN", 2)
    3.times { |i| chat("u#{i}") }
    allow(gql).to receive(:batch_bot_check) { |logins:| logins.map { |l| profile(login: l) } }

    worker.perform
    expect(ChatterProfile.count).to eq(2)
  end

  it "asks ClickHouse for OVERSAMPLE_LIMIT candidates and trims to MAX_PER_RUN after the Ruby filter" do
    # Regression guard for the cross-DB pattern: CH must oversample (worst-case 95%+ cache hit) so
    # the Ruby set-difference still yields a usable batch.
    expect(Clickhouse::ChatQueries).to receive(:distinct_active_chatters).with(
      since: a_value_within(5.seconds).of(ChatterProfileRefreshWorker::LOOKBACK.ago),
      limit: ChatterProfileRefreshWorker::OVERSAMPLE_LIMIT
    ).and_return([])

    worker.perform
  end

  # BUG-C (2026-07-21): fraud-prioritized selection — chatters on live monitored streams are
  # profiled FIRST, so a fresh single-channel fake on a channel we're scoring can't stay invisible.
  describe "fraud-prioritized selection" do
    before { create(:stream, ended_at: nil) } # ≥1 live monitored stream → priority path active

    it "profiles live-stream chatters BEFORE general backfill within the fixed budget" do
      stub_const("ChatterProfileRefreshWorker::MAX_PER_RUN", 2)
      live_chat("livefake1")
      live_chat("livefake2")           # priority set (on a live monitored stream)
      chat("backfill1")
      chat("backfill2")                # general recent chatters (lower priority)
      allow(gql).to receive(:batch_bot_check) { |logins:| logins.map { |l| profile(login: l) } }

      worker.perform
      # budget of 2 spent on the priority set, NOT the arbitrary backfill
      expect(ChatterProfile.pluck(:login)).to contain_exactly("livefake1", "livefake2")
    end

    it "profiles a fresh single-channel fake on a live stream (matvey228666337-class regression)" do
      live_chat("matvey228666337")
      allow(gql).to receive(:batch_bot_check)
        .with(logins: [ "matvey228666337" ])
        .and_return([ profile(login: "matvey228666337", created_at: 12.minutes.ago.utc.iso8601, followers: 0) ])

      expect { worker.perform }.to change(ChatterProfile, :count).by(1)
      expect(ChatterProfile.find_by(login: "matvey228666337")).to be_present
    end

    it "falls back to general backfill when no stream is live" do
      Stream.update_all(ended_at: Time.current) # no active streams → priority empty
      chat("only_backfill")
      allow(gql).to receive(:batch_bot_check).with(logins: [ "only_backfill" ]).and_return([ profile(login: "only_backfill") ])

      expect { worker.perform }.to change(ChatterProfile, :count).by(1)
    end
  end
end
