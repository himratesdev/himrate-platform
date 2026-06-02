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

  # CR-256 P3 (spec hygiene): use `around { |ex| travel { ex.run } }` instead of bare
  # `travel … travel_back` — guarantees clock reset even if an assertion raises mid-block.

  it "GrowthSignals: features identical between immediate run and +5h-later run" do
    immediate = Ml::Features::GrowthSignals.new(stream).call
    travel(5.hours) do
      later = Ml::Features::GrowthSignals.new(stream).call
      expect(later).to eq(immediate), "growth features drifted: immediate=#{immediate.inspect}, +5h=#{later.inspect}"
    end
  end

  it "StabilitySignals: features identical between immediate run and +5h-later run" do
    immediate = Ml::Features::StabilitySignals.new(stream).call
    travel(5.hours) do
      later = Ml::Features::StabilitySignals.new(stream).call
      expect(later).to eq(immediate), "stability features drifted: immediate=#{immediate.inspect}, +5h=#{later.inspect}"
    end
  end

  it "MaturitySignals: features identical between immediate run and +5h-later run" do
    immediate = Ml::Features::MaturitySignals.new(stream).call
    travel(5.hours) do
      later = Ml::Features::MaturitySignals.new(stream).call
      expect(later).to eq(immediate), "maturity features drifted: immediate=#{immediate.inspect}, +5h=#{later.inspect}"
    end
  end

  it "AccountSignals: features identical between immediate run and +5h-later run" do
    immediate = Ml::Features::AccountSignals.new(stream).call
    travel(5.hours) do
      later = Ml::Features::AccountSignals.new(stream).call
      expect(later).to eq(immediate), "account features drifted: immediate=#{immediate.inspect}, +5h=#{later.inspect}"
    end
  end

  it "extreme delayed-queue scenario: same features after 30 days replay" do
    immediate = Ml::Features::MaturitySignals.new(stream).call
    travel(30.days) do
      delayed_replay = Ml::Features::MaturitySignals.new(stream).call
      expect(delayed_replay[:account_age_days_capped]).to eq(immediate[:account_age_days_capped]),
             "account_age_days_capped drifted by 30d replay (anchor not applied): " \
             "immediate=#{immediate[:account_age_days_capped]}, +30d=#{delayed_replay[:account_age_days_capped]}"
    end
  end

  # CR-256 P1 spec coverage: insert source rows AFTER `stream.ended_at` between immediate
  # and replay — full upper-bound anchoring must EXCLUDE these from the window.
  describe "upper-bound anchoring — post-anchor source rows excluded on replay" do
    it "GrowthSignals: post-anchor FollowerSnapshot does NOT change features" do
      immediate = Ml::Features::GrowthSignals.new(stream).call
      # Create a new snapshot AFTER stream.ended_at — represents data that didn't exist
      # at extraction time. Replay must ignore it.
      create(:follower_snapshot,
             channel: channel,
             followers_count: 99_999, # outlier value — would visibly shift CV / churn if leaked
             timestamp: stream.ended_at + 2.hours)
      travel(5.hours) do
        replay = Ml::Features::GrowthSignals.new(stream).call
        expect(replay).to eq(immediate),
               "growth features leaked post-anchor FollowerSnapshot — replay=#{replay.inspect}"
      end
    end

    it "StabilitySignals: post-anchor TIH does NOT change features" do
      immediate = Ml::Features::StabilitySignals.new(stream).call
      future_stream = create(:stream, channel: channel,
                             started_at: stream.ended_at + 1.hour,
                             ended_at: stream.ended_at + 2.hours)
      TrustIndexHistory.create!(
        channel: channel, stream: future_stream,
        trust_index_score: 10, # outlier — would shift std if leaked
        calculated_at: stream.ended_at + 2.hours
      )
      travel(5.hours) do
        replay = Ml::Features::StabilitySignals.new(stream).call
        expect(replay).to eq(immediate),
               "stability features leaked post-anchor TIH — replay=#{replay.inspect}"
      end
    end

    it "MaturitySignals: post-anchor completed Stream does NOT change features" do
      immediate = Ml::Features::MaturitySignals.new(stream).call
      # New completed stream after our @stream — would inflate total_streams_capped / hours
      # without the upper-bound filter on completed_stream_durations_sec.
      create(:stream, channel: channel,
             started_at: stream.ended_at + 1.hour,
             ended_at: stream.ended_at + 2.hours)
      travel(5.hours) do
        replay = Ml::Features::MaturitySignals.new(stream).call
        expect(replay).to eq(immediate),
               "maturity features leaked post-anchor stream — replay=#{replay.inspect}"
      end
    end

    it "AccountSignals.engagement_participation_ratio: post-anchor FollowerSnapshot does NOT shift denominator" do
      immediate = Ml::Features::AccountSignals.new(stream).call[:engagement_participation_ratio]
      # New snapshot with 10× followers — would invalidate the original-time engagement ratio.
      create(:follower_snapshot,
             channel: channel,
             followers_count: (stream.channel.follower_snapshots.maximum(:followers_count) || 1000) * 10,
             timestamp: stream.ended_at + 2.hours)
      travel(5.hours) do
        replay = Ml::Features::AccountSignals.new(stream).call[:engagement_participation_ratio]
        expect(replay).to eq(immediate),
               "engagement_participation_ratio leaked post-anchor FollowerSnapshot — " \
               "immediate=#{immediate.inspect}, replay=#{replay.inspect}"
      end
    end
  end

  # CR-256 P2 (scope clarification): time-anchor determinism does NOT cover data-side
  # mutability of `ChatterProfile.{followers,follows}_count` (refreshed by
  # `ChatterProfileRefreshWorker` on a staleness cadence). A backfill weeks later sees the
  # CURRENT cached values for the same set of chatters. Snapshotting these on-extract
  # requires per-stream column extension on `stream_feature_vectors` — separate follow-up
  # ticket. This spec documents the boundary, not the fix.
  describe "P2 — data-side mutability boundary (informational, not a regression)" do
    it "documents that ChatterProfile mutation can drift profile_completeness_ratio" do
      immediate = Ml::Features::AccountSignals.new(stream).call[:profile_completeness_ratio]
      # Simulate worker refreshing ChatterProfile cache with stale-flipped-to-empty values.
      ChatterProfile.where(login: stream.per_user_bot_scores.pluck(:username))
                    .update_all(followers_count: 0, follows_count: 0)
      replay = Ml::Features::AccountSignals.new(stream).call[:profile_completeness_ratio]
      # Document: time anchor doesn't save us here — values legitimately moved.
      expect(replay).not_to eq(immediate),
             "expected demonstration of P2 mutability drift — if this fails the data " \
             "model changed (e.g. per-stream snapshot extension landed) and this spec " \
             "should be updated"
    end
  end
end
