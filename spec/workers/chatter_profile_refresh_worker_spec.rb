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
  end

  def chat(username, ts: 10.minutes.ago)
    ch_chatters << { username: username, at: ts }
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
end
