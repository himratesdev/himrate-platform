# frozen_string_literal: true

require "rails_helper"

# CR-253 M1 cleanup verification: feature derivation is deterministic when the "wall-clock"
# advances. Same `(stream_id, version)` row must yield same numeric features regardless of
# whether the worker fires immediately (`PostStreamWorker`) or hours later (delayed queue /
# schema_version replay / training-time backfill).
#
# Strategy: same stream + same source data, twice — Time.current shifted hours forward
# between runs — features MUST be identical. Pre-cleanup: features would drift because
# `WINDOW.ago` / `Time.current - twitch_created_at` slid forward; post-cleanup: anchored
# to `@stream.ended_at` (fallback `started_at`) → constant.
RSpec.describe "ML feature extraction determinism (CR-253 M1)" do
  include ActiveSupport::Testing::TimeHelpers

  let(:channel) { create(:channel, twitch_created_at: 200.days.ago) }
  let(:stream) do
    # Fixed end-of-broadcast — the anchor for all temporal derivations.
    create(:stream, channel: channel, started_at: 2.hours.ago, ended_at: 1.hour.ago)
  end

  before do
    # CH ingress not invoked by these services (Growth/Stability use PG + nothing CH;
    # Maturity uses PG; Account uses PG ChatterProfile). But stub anyway for safety
    # — extractor_spec pattern.
    allow(Clickhouse::ChatQueries).to receive(:chat_feature_aggregates).and_return({})
    allow(Clickhouse::ChatQueries).to receive(:privmsg_counts_for_streams).and_return({})

    # Seed data for each group в анкеренном scope.
    # Growth: 15 follower snapshots, last is at stream.ended_at - 1.day.
    15.times do |i|
      create(:follower_snapshot,
             channel: channel,
             followers_count: 1000 + i * 10,
             timestamp: stream.ended_at - (14 - i).days)
    end
    # Stability: 6 TIH rows linked to past streams.
    6.times do |i|
      past = create(:stream, channel: channel,
                    started_at: stream.ended_at - (i + 2).hours,
                    ended_at: stream.ended_at - (i + 1).hours)
      TrustIndexHistory.create!(
        channel: channel, stream: past,
        trust_index_score: 75 + i,
        calculated_at: stream.ended_at - (i + 1).hours
      )
    end
    # Account: 12 chatters с ChatterProfiles.
    12.times do |i|
      login = "u_#{i}"
      create(:per_user_bot_score, stream: stream, username: login)
      ChatterProfile.create!(
        login: login, twitch_user_id: "tu_#{i}",
        twitch_created_at: (500 + i * 50).days.ago,
        followers_count: 10, follows_count: 5, fetched_at: Time.current
      )
    end
  end

  it "GrowthSignals: features identical between immediate run and +5h-later run" do
    immediate = Ml::Features::GrowthSignals.new(stream).call
    travel 5.hours
    later = Ml::Features::GrowthSignals.new(stream).call
    travel_back
    expect(later).to eq(immediate), "growth features drifted: immediate=#{immediate.inspect}, +5h=#{later.inspect}"
  end

  it "StabilitySignals: features identical between immediate run and +5h-later run" do
    immediate = Ml::Features::StabilitySignals.new(stream).call
    travel 5.hours
    later = Ml::Features::StabilitySignals.new(stream).call
    travel_back
    expect(later).to eq(immediate), "stability features drifted: immediate=#{immediate.inspect}, +5h=#{later.inspect}"
  end

  it "MaturitySignals: features identical between immediate run and +5h-later run" do
    immediate = Ml::Features::MaturitySignals.new(stream).call
    travel 5.hours
    later = Ml::Features::MaturitySignals.new(stream).call
    travel_back
    expect(later).to eq(immediate), "maturity features drifted: immediate=#{immediate.inspect}, +5h=#{later.inspect}"
  end

  it "AccountSignals: features identical between immediate run and +5h-later run" do
    immediate = Ml::Features::AccountSignals.new(stream).call
    travel 5.hours
    later = Ml::Features::AccountSignals.new(stream).call
    travel_back
    expect(later).to eq(immediate), "account features drifted: immediate=#{immediate.inspect}, +5h=#{later.inspect}"
  end

  it "extreme delayed-queue scenario: same features after 30 days replay" do
    immediate = Ml::Features::MaturitySignals.new(stream).call
    travel 30.days
    delayed_replay = Ml::Features::MaturitySignals.new(stream).call
    travel_back
    expect(delayed_replay[:account_age_days_capped]).to eq(immediate[:account_age_days_capped]),
           "account_age_days_capped drifted by 30d replay (anchor not applied): " \
           "immediate=#{immediate[:account_age_days_capped]}, +30d=#{delayed_replay[:account_age_days_capped]}"
  end
end
