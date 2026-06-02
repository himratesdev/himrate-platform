# frozen_string_literal: true

require "rails_helper"

# PR 1e-A (2026-05-31): post-CH-cutover BotScoringWorker reads chat from ClickHouse
# (Clickhouse::ChatQueries.chatter_aggregations/timestamps/messages/emotes/cross_channel_counts)
# instead of PG ChatMessage. Specs stub the 5 ChatQueries methods to feed deterministic
# per-user data into the scorer pipeline — same per_user_bot_scores assertions as the
# PG era, just sourced through the CH-shaped interface.
RSpec.describe BotScoringWorker do
  let(:worker) { described_class.new }

  before do
    allow(Flipper).to receive(:enabled?).with(:bot_scoring).and_return(true)
    # CR-258 S1: BSW now checks Flipper[:cross_channel_digest] inside fetch_cross_channel_counts.
    # Default OFF so legacy `Clickhouse::ChatQueries.chatter_cross_channel_counts` path is exercised
    # by all pre-existing tests; the new dedicated `describe "cross-channel routing"` block flips
    # it ON explicitly.
    allow(Flipper).to receive(:enabled?).with(:cross_channel_digest).and_return(false)
    # Default: no chat returned. Each test overrides the methods it depends on.
    allow(Clickhouse::ChatQueries).to receive(:chatter_aggregations).and_return({})
    allow(Clickhouse::ChatQueries).to receive(:chatter_timestamps).and_return({})
    allow(Clickhouse::ChatQueries).to receive(:chatter_messages).and_return({})
    allow(Clickhouse::ChatQueries).to receive(:chatter_emotes).and_return({})
    allow(Clickhouse::ChatQueries).to receive(:chatter_cross_channel_counts).and_return({})
  end

  # Helper: build the chatter_aggregations Hash shape Clickhouse::ChatQueries returns.
  def aggregation(username, msg_count: 3, user_type: nil, sub: nil, badge: nil,
                  returning: false, vip: false, bits: 0)
    {
      irc_tags: {
        user_type: user_type, subscriber_status: sub, badge_info: badge,
        returning_chatter: returning, vip: vip, bits_used: bits
      },
      chat_stats: { message_count: msg_count }
    }
  end

  # Phase 5 (2026-05-31): dedicated :bot_scoring queue so cron-enqueued jobs don't sit behind
  # the 700k+ :signals backlog. Regression guard: if this drops back to :signals, the
  # chat_behavior / known_bot_match / account_profile_scoring signals re-break on live streams.
  it "uses the dedicated :bot_scoring queue (weighted-random, fetch share ≈17% vs :signals)" do
    expect(described_class.sidekiq_options["queue"]).to eq("bot_scoring")
  end

  # AC-09: BotScoringWorker batch scores all chatters after stream ends
  it "scores chatters and writes to per_user_bot_scores" do
    channel = Channel.create!(twitch_id: "123", login: "test_channel", display_name: "Test")
    stream = Stream.create!(channel: channel, started_at: 2.hours.ago, ended_at: 1.hour.ago)

    allow(Clickhouse::ChatQueries).to receive(:chatter_aggregations).with(stream).and_return(
      "user_0" => aggregation("user_0"),
      "user_1" => aggregation("user_1"),
      "user_2" => aggregation("user_2")
    )
    allow_any_instance_of(KnownBotService).to receive(:check_batch).and_return(
      "user_0" => { bot: false, confidence: 0.0, sources: [] },
      "user_1" => { bot: false, confidence: 0.0, sources: [] },
      "user_2" => { bot: false, confidence: 0.0, sources: [] }
    )

    expect { worker.perform(stream.id) }.to change(PerUserBotScore, :count).by(3)

    scores = PerUserBotScore.where(stream: stream)
    expect(scores.pluck(:username)).to contain_exactly("user_0", "user_1", "user_2")
    scores.each do |s|
      expect(s.bot_score).to be_between(0.0, 1.0)
      expect(s.classification).to be_in(PerUserBotScore::CLASSIFICATIONS)
      expect(s.components).to be_a(Hash)
    end
  end

  it "skips when Flipper disabled" do
    allow(Flipper).to receive(:enabled?).with(:bot_scoring).and_return(false)
    expect { worker.perform("some-id") }.not_to change(PerUserBotScore, :count)
  end

  it "handles missing stream gracefully" do
    expect { worker.perform("nonexistent-id") }.not_to raise_error
  end

  # TASK-251.W2b: BotScoringWorker reads cached ChatterProfile (no GQL) → feeds
  # Scorer#score_profile → Account Profile Scoring (#11) components are populated.
  it "feeds cached chatter profile into bot-score components (#11 revival)" do
    channel = Channel.create!(twitch_id: "777", login: "prof_channel", display_name: "Prof")
    stream = Stream.create!(channel: channel, started_at: 2.hours.ago, ended_at: 1.hour.ago)
    allow(Clickhouse::ChatQueries).to receive(:chatter_aggregations).with(stream).and_return(
      "botty" => aggregation("botty")
    )
    ChatterProfile.create!(login: "botty", twitch_created_at: 2.days.ago, followers_count: 0,
                           follows_count: 0, fetched_at: Time.current)
    allow_any_instance_of(KnownBotService).to receive(:check_batch).and_return("botty" => { bot: false, confidence: 0.0, sources: [] })

    worker.perform(stream.id)

    components = PerUserBotScore.find_by(stream: stream, username: "botty").components.keys.map(&:to_s)
    # Profile was scored (marker) + genuine bot flags present (were never set when profile was nil).
    expect(components).to include("profile_present", "followers_zero", "account_age_7d", "follows_zero")
  end

  # TASK-251.W2b: a normal viewer's profile (old account, has followers, follows channels) must NOT
  # be flagged — only the zero-weight profile_present marker, no suspicious flags.
  it "does NOT flag a normal viewer's cached profile (calibration: no streamer-presence flags)" do
    channel = Channel.create!(twitch_id: "779", login: "viewer_channel", display_name: "V")
    stream = Stream.create!(channel: channel, started_at: 2.hours.ago, ended_at: 1.hour.ago)
    allow(Clickhouse::ChatQueries).to receive(:chatter_aggregations).with(stream).and_return(
      "realviewer" => aggregation("realviewer")
    )
    ChatterProfile.create!(login: "realviewer", twitch_created_at: 3.years.ago, followers_count: 25,
                           follows_count: 120, fetched_at: Time.current)
    allow_any_instance_of(KnownBotService).to receive(:check_batch).and_return("realviewer" => { bot: false, confidence: 0.0, sources: [] })

    worker.perform(stream.id)

    components = PerUserBotScore.find_by(stream: stream, username: "realviewer").components.keys.map(&:to_s)
    expect(components).to include("profile_present")
    expect(components).not_to include("followers_zero", "account_age_7d", "account_age_30d", "follows_zero")
  end

  it "handles stream with 0 chatters (empty Clickhouse::ChatQueries.chatter_aggregations)" do
    channel = Channel.create!(twitch_id: "456", login: "empty_channel", display_name: "Empty")
    stream = Stream.create!(channel: channel, started_at: 2.hours.ago, ended_at: 1.hour.ago)
    # chatter_aggregations stub already defaults to {} via the top-level before block.

    expect { worker.perform(stream.id) }.not_to change(PerUserBotScore, :count)
  end

  # CR-258 S1 (BUG-SCW-CROSS-CHANNEL): BSW shared the same 24h CH scan on its own queue, so the
  # all-callers-of-the-primitive lesson from BUG-251.40 applies. When Flipper[:cross_channel_digest]
  # is ON, BSW must read from the digest with the same `fetch_with_baseline` semantics that
  # ContextBuilder uses (post-fill missing usernames with 1) — otherwise the cross_channel_count
  # passed to the scorer collapses for single-channel chatters.
  describe "cross-channel routing (CR-258 S1, BUG-SCW-CROSS-CHANNEL digest path)" do
    let(:channel) { Channel.create!(twitch_id: "999", login: "cc_test", display_name: "CC") }
    let(:stream) { Stream.create!(channel: channel, started_at: 2.hours.ago, ended_at: 1.hour.ago) }

    before do
      allow(Clickhouse::ChatQueries).to receive(:chatter_aggregations).with(stream).and_return(
        "alice"  => aggregation("alice"),
        "newbie" => aggregation("newbie")
      )
      allow_any_instance_of(KnownBotService).to receive(:check_batch).and_return(
        "alice"  => { bot: false, confidence: 0.0, sources: [] },
        "newbie" => { bot: false, confidence: 0.0, sources: [] }
      )
    end

    it "uses the digest (with single-channel baseline = 1) when Flipper :cross_channel_digest ON" do
      allow(Flipper).to receive(:enabled?).with(:cross_channel_digest).and_return(true)
      CrossChannelDigest.upsert_all([
        { username: "alice", distinct_channels_24h: 6, refreshed_at: Time.current }
      ], unique_by: :username)
      expect(Clickhouse::ChatQueries).not_to receive(:chatter_cross_channel_counts)

      worker.perform(stream.id)

      alice_score = PerUserBotScore.find_by(stream: stream, username: "alice")
      newbie_score = PerUserBotScore.find_by(stream: stream, username: "newbie")
      expect(alice_score.components["cross_channel_count"]).to eq(6)
      expect(newbie_score.components["cross_channel_count"]).to eq(1) # post-fill baseline
    end

    it "falls back to the legacy CH scan when Flipper :cross_channel_digest OFF" do
      allow(Flipper).to receive(:enabled?).with(:cross_channel_digest).and_return(false)
      expect(Clickhouse::ChatQueries).to receive(:chatter_cross_channel_counts)
        .with(%w[alice newbie], instance_of(ActiveSupport::TimeWithZone))
        .and_return("alice" => 6) # legacy returns whatever CH says; absent → 0 via `|| 0`

      worker.perform(stream.id)

      expect(PerUserBotScore.find_by(stream: stream, username: "alice").components["cross_channel_count"]).to eq(6)
      expect(PerUserBotScore.find_by(stream: stream, username: "newbie").components["cross_channel_count"]).to eq(0)
    end
  end
end
