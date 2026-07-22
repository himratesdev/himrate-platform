# frozen_string_literal: true

require "rails_helper"

RSpec.describe SocialAnalytics::Attribution::StreamerFunnel do
  let(:login) { "recrent" }
  let(:channel) { create(:channel, login: login) }

  def profile_with_telegram_posts(posts)
    { login: login, platforms: { telegram: { available: true, recent_posts: posts } } }
  end

  describe "Telegram per-post correlation" do
    it "correlates a post that follows a stream within the uplift window and flags a view spike" do
      stream_at = Time.utc(2026, 7, 20, 12, 0, 0)
      create(:stream, channel: channel, started_at: stream_at, ended_at: stream_at + 3.hours)

      posts = [
        { views: 300_000, at: (stream_at + 8.hours).iso8601 }, # follows the stream + a spike
        { views: 90_000, at: (stream_at - 5.days).iso8601 }, # baseline, no preceding stream
        { views: 100_000, at: (stream_at - 6.days).iso8601 }
      ]

      result = described_class.call(login, profile: profile_with_telegram_posts(posts))
      tg = result[:telegram]

      expect(tg[:available]).to be(true)
      expect(tg[:posts_analyzed]).to eq(3)
      expect(tg[:stream_associated_post_count]).to eq(1)
      expect(tg[:stream_associated_spikes]).to eq(1)

      correlated = tg[:stream_associated_posts].first
      expect(correlated[:views]).to eq(300_000)
      expect(correlated[:hours_after_stream]).to eq(8.0)
      expect(correlated[:is_spike]).to be(true)
      expect(correlated[:uplift_ratio]).to be > 1.3
      expect(correlated[:preceding_stream_at]).to eq(stream_at.iso8601)
    end

    it "does not correlate a post that precedes every stream" do
      stream_at = Time.utc(2026, 7, 20, 12, 0, 0)
      create(:stream, channel: channel, started_at: stream_at, ended_at: stream_at + 1.hour)

      posts = [ { views: 300_000, at: (stream_at - 2.hours).iso8601 } ] # BEFORE the stream
      result = described_class.call(login, profile: profile_with_telegram_posts(posts))

      expect(result[:telegram][:stream_associated_post_count]).to eq(0)
    end

    it "does not correlate a post outside the uplift window (too long after the stream)" do
      stream_at = Time.utc(2026, 7, 20, 12, 0, 0)
      create(:stream, channel: channel, started_at: stream_at, ended_at: stream_at + 1.hour)

      posts = [ { views: 300_000, at: (stream_at + 40.hours).iso8601 } ] # past UPLIFT_WINDOW (36h)
      result = described_class.call(login, profile: profile_with_telegram_posts(posts))

      expect(result[:telegram][:stream_associated_post_count]).to eq(0)
    end

    it "degrades to unavailable when Telegram is not analysed" do
      result = described_class.call(login, profile: { login: login, platforms: {} })
      expect(result[:telegram]).to eq({ available: false })
    end

    it "degrades to unavailable when posts carry no parseable timestamps" do
      posts = [ { views: 300_000, at: "not-a-date" } ]
      result = described_class.call(login, profile: profile_with_telegram_posts(posts))
      expect(result[:telegram]).to eq({ available: false, reason: "no_dated_posts" })
    end
  end

  describe "snapshot subscriber growth vs stream cadence" do
    it "reports per-interval deltas and counts streams inside each interval" do
      base = Time.utc(2026, 7, 1, 0, 0, 0)
      create(:social_profile_snapshot, twitch_login: login, platform: "telegram", captured_at: base, subscribers: 100_000)
      create(:social_profile_snapshot, twitch_login: login, platform: "telegram", captured_at: base + 2.days, subscribers: 102_000)
      # a stream inside the interval
      create(:stream, channel: channel, started_at: base + 1.day, ended_at: base + 1.day + 2.hours)

      result = described_class.call(login, profile: { login: login, platforms: {} })
      growth = result[:subscriber_growth]["telegram"]

      expect(growth[:coverage]).to eq("building")
      expect(growth[:intervals].size).to eq(1)
      interval = growth[:intervals].first
      expect(interval[:delta]).to eq(2_000)
      expect(interval[:streams]).to eq(1)
      expect(growth[:stream_covered_daily_growth]).to eq(1000.0) # 2000 over 2 days
      expect(growth[:stream_free_daily_growth]).to be_nil
    end

    it "omits a platform with fewer than two snapshots (no interval yet)" do
      create(:social_profile_snapshot, twitch_login: login, platform: "telegram", captured_at: Time.utc(2026, 7, 1), subscribers: 100_000)
      result = described_class.call(login, profile: { login: login, platforms: {} })
      expect(result[:subscriber_growth]).not_to have_key("telegram")
    end
  end

  describe "envelope" do
    it "always carries the temporal-correlation disclaimer and the stream count" do
      channel # ensure it exists
      create(:stream, channel: channel, started_at: 2.days.ago, ended_at: 2.days.ago + 1.hour)

      result = described_class.call(login, profile: { login: login, platforms: {} })

      expect(result[:disclaimer]).to include("временная корреляция")
      expect(result[:streams_in_window]).to eq(1)
      expect(result[:window_days]).to eq(90)
    end

    it "handles an unknown channel (no streams) without error" do
      result = described_class.call("nobody_here", profile: { platforms: {} })
      expect(result[:streams_in_window]).to eq(0)
      expect(result[:telegram]).to eq({ available: false })
    end
  end
end
