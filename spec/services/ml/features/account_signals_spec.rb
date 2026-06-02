# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ml::Features::AccountSignals do
  let(:channel) { create(:channel) }
  let(:stream) { create(:stream, channel: channel) }
  let(:account) { described_class.new(stream) }

  # Helpers: seed PerUserBotScore + ChatterProfile for the stream's chatters
  def seed_chatters(n, profile_overrides_per_user: {})
    n.times do |i|
      login = "chatter_#{i}"
      create(:per_user_bot_score, stream: stream, username: login)
      ChatterProfile.create!(
        login: login,
        twitch_user_id: "user_#{i}",
        twitch_created_at: (1000 + i * 100).days.ago,
        followers_count: 10 + i,
        follows_count: 5 + i,
        fetched_at: Time.current,
        **(profile_overrides_per_user[login] || {})
      )
    end
  end

  describe "#call (cold-start — no chatters)" do
    it "all 4 features nil with 'no_chatters' reason" do
      result = account.call
      expect(result.values).to all(be_nil)
      reasons = account.insufficient_data_reasons
      expect(reasons.keys).to match_array(%i[
        avg_account_age_days account_creation_date_clustering_gini
        profile_completeness_ratio engagement_participation_ratio
      ])
      expect(reasons.values.uniq).to eq([ "no_chatters" ])
    end
  end

  describe "#call (chatters without cached profiles)" do
    it "marks features 'no_cached_profiles'" do
      3.times { |i| create(:per_user_bot_score, stream: stream, username: "phantom_#{i}") }

      account.call
      reasons = account.insufficient_data_reasons
      expect(reasons[:avg_account_age_days]).to eq("no_cached_profiles")
      expect(reasons[:account_creation_date_clustering_gini]).to eq("no_cached_profiles")
      expect(reasons[:profile_completeness_ratio]).to eq("no_cached_profiles")
    end
  end

  describe "#call (insufficient profiles — < MIN)" do
    it "marks features 'insufficient_profiles'" do
      seed_chatters(5) # < MIN_PROFILES_FOR_RATIO_FEATURES (10)

      account.call
      reasons = account.insufficient_data_reasons
      expect(reasons[:avg_account_age_days]).to eq("insufficient_profiles")
      expect(reasons[:account_creation_date_clustering_gini]).to eq("insufficient_profiles")
      expect(reasons[:profile_completeness_ratio]).to eq("insufficient_profiles")
    end
  end

  describe "#call (profiles exist but all twitch_created_at nil — CR-251 N3)" do
    # M1 (iter-2) introduced a new reachable branch: cached profiles exist (passes
    # insufficient_account_data_reason ladder) but ALL have nil twitch_created_at.
    # Age-based features fall into "no_profiles_with_creation_date" reason.
    it "returns nil for age/Gini with 'no_profiles_with_creation_date' reason" do
      15.times do |i|
        login = "ndchatter_#{i}"
        create(:per_user_bot_score, stream: stream, username: login)
        ChatterProfile.create!(
          login: login, twitch_user_id: "u_#{i}",
          twitch_created_at: nil, # пробел в кеше
          followers_count: 10, follows_count: 5, fetched_at: Time.current
        )
      end

      result = account.call
      expect(result[:avg_account_age_days]).to be_nil
      expect(result[:account_creation_date_clustering_gini]).to be_nil
      expect(account.insufficient_data_reasons[:avg_account_age_days]).to eq("no_profiles_with_creation_date")
      expect(account.insufficient_data_reasons[:account_creation_date_clustering_gini]).to eq("no_profiles_with_creation_date")
    end

    it "profile_completeness_ratio still computes (doesn't depend on creation date)" do
      15.times do |i|
        login = "ndchatter_pc_#{i}"
        create(:per_user_bot_score, stream: stream, username: login)
        ChatterProfile.create!(
          login: login, twitch_user_id: "u_pc_#{i}",
          twitch_created_at: nil,
          followers_count: 10, follows_count: 5, fetched_at: Time.current
        )
      end

      result = account.call
      expect(result[:profile_completeness_ratio]).to eq(1.0)
    end
  end

  describe "#call (happy-path — ≥10 cached profiles)" do
    before { seed_chatters(15) }

    it "computes avg_account_age_days as mean of (now - twitch_created_at) in days" do
      result = account.call
      # Profiles created at 1000..2400 days ago → mean ≈ 1700 days
      expect(result[:avg_account_age_days]).to be_within(50).of(1700)
    end

    it "computes account_creation_date_clustering_gini in [0..1]" do
      result = account.call
      expect(result[:account_creation_date_clustering_gini]).to be_between(0, 1).inclusive
    end

    it "profile_completeness_ratio = 1.0 when all profiles have followers+follows > 0" do
      # Default seed gives followers/follows = 10+i/5+i (all > 0)
      result = account.call
      expect(result[:profile_completeness_ratio]).to eq(1.0)
    end

    it "profile_completeness_ratio drops when some profiles have zero followers" do
      # Mark half с zero followers
      8.times { |i| ChatterProfile.find_by(login: "chatter_#{i}").update!(followers_count: 0) }

      result = described_class.new(stream).call
      expect(result[:profile_completeness_ratio]).to be_within(0.001).of(7.0 / 15.0)
    end
  end

  describe "#engagement_participation_ratio" do
    # CR-256 P1: fixture timestamps anchored to stream.ended_at, NOT Time.current. Without
    # this shift, `1.hour.ago` evaluates microseconds later than stream's ended_at and gets
    # excluded by the new upper-bound filter on `latest_snapshot`.
    it "computes unique_chatters / channel.followers (latest FollowerSnapshot)" do
      seed_chatters(5) # 5 unique chatters
      create(:follower_snapshot, channel: channel, followers_count: 1000, timestamp: stream.ended_at - 1.hour)

      result = account.call
      expect(result[:engagement_participation_ratio]).to eq(0.005) # 5/1000
    end

    it "uses LATEST at-or-before extraction_anchor snapshot when multiple exist" do
      seed_chatters(5)
      create(:follower_snapshot, channel: channel, followers_count: 5000, timestamp: stream.ended_at - 2.hours)
      create(:follower_snapshot, channel: channel, followers_count: 100, timestamp: stream.ended_at - 1.hour)

      result = account.call
      expect(result[:engagement_participation_ratio]).to eq(0.05) # 5/100 — latest at-or-before anchor
    end

    it "nil when no follower snapshot exists" do
      seed_chatters(5)
      # no follower snapshot

      result = account.call
      expect(result[:engagement_participation_ratio]).to be_nil
      expect(account.insufficient_data_reasons[:engagement_participation_ratio]).to eq("no_follower_snapshot")
    end

    # CR-251 S1 (iter-2): distinguish no_follower_snapshot vs zero_followers
    it "nil with 'zero_followers' when snapshot exists но followers_count = 0 (brand-new channel)" do
      seed_chatters(5)
      create(:follower_snapshot, channel: channel, followers_count: 0, timestamp: stream.ended_at - 1.hour)

      result = account.call
      expect(result[:engagement_participation_ratio]).to be_nil
      expect(account.insufficient_data_reasons[:engagement_participation_ratio]).to eq("zero_followers")
    end
  end
end
