# frozen_string_literal: true

require "rails_helper"

# SCORE = view_count + PROJECTION_HOURS × velocity, velocity measured between the oldest and newest
# snapshot inside VELOCITY_WINDOW. No snapshots → velocity 0 → the score IS view_count.
RSpec.describe Channels::ClipsQuery do
  let(:channel) { create(:channel, twitch_id: "555000") }

  def clip(slug, views:, created_at: 2.days.ago, broadcaster: channel.twitch_id)
    create(:farm_clip, clip_id: slug, view_count: views, broadcaster_twitch_id: broadcaster,
                       twitch_created_at: created_at)
  end

  # Two snapshots `hours` apart ending at `views` — i.e. a measured (views - from) / hours velocity.
  def climb(record, from:, to:, hours:)
    create(:farm_clip_view_snapshot, farm_clip: record, view_count: from, captured_at: hours.hours.ago)
    create(:farm_clip_view_snapshot, farm_clip: record, view_count: to, captured_at: Time.current)
  end

  def slugs(limit: nil)
    described_class.new(channel: channel, limit: limit).call.map(&:clip_id)
  end

  it "falls back to raw views when a clip has no snapshots at all" do
    clip("quiet_big", views: 900)
    clip("quiet_small", views: 100)

    expect(slugs).to eq(%w[quiet_big quiet_small])
  end

  it "lets a climbing clip overtake a bigger, static one" do
    static = clip("static", views: 1_000)
    rising = clip("rising", views: 700)
    climb(static, from: 995, to: 1_000, hours: 5)    # ~1/h → score ≈ 1006
    climb(rising, from: 400, to: 700, hours: 5)      # 60/h → score ≈ 1060

    expect(slugs.first).to eq("rising")
  end

  it "does not let momentum alone displace the channel's actual best clip" do
    clip("best", views: 10_000)
    spike = clip("spike", views: 200)
    climb(spike, from: 0, to: 200, hours: 1) # 200/h → score 1400, still far below 10_000

    expect(slugs).to eq(%w[best spike])
  end

  it "ignores a burst too short to measure (both snapshots inside MIN_SPAN_HOURS)" do
    narrow = clip("narrow", views: 500)
    other = clip("other", views: 600)
    create(:farm_clip_view_snapshot, farm_clip: narrow, view_count: 100, captured_at: 10.minutes.ago)
    create(:farm_clip_view_snapshot, farm_clip: narrow, view_count: 500, captured_at: Time.current)

    expect(slugs).to eq(%w[other narrow]) # narrow scored on its 500 views, not on 2400/h
  end

  it "ignores snapshots older than the velocity window" do
    stale = clip("stale", views: 500)
    fresh = clip("fresh", views: 600)
    create(:farm_clip_view_snapshot, farm_clip: stale, view_count: 0, captured_at: 20.days.ago)
    create(:farm_clip_view_snapshot, farm_clip: stale, view_count: 500, captured_at: 19.days.ago)

    expect(slugs).to eq(%w[fresh stale])
  end

  it "never reads a negative velocity as a penalty (a re-counted clip keeps its views)" do
    shrunk = clip("shrunk", views: 800)
    climb(shrunk, from: 900, to: 800, hours: 5)

    expect(slugs).to eq(%w[shrunk])
  end

  it "serves only that broadcaster's clips" do
    clip("ours", views: 100)
    clip("theirs", views: 9_000, broadcaster: "999111")

    expect(slugs).to eq(%w[ours])
  end

  it "defaults to 12 clips and never serves more than 24" do
    30.times { |i| clip("c#{i.to_s.rjust(2, '0')}", views: 1_000 - i) }

    expect(slugs.size).to eq(described_class::DEFAULT_LIMIT)
    expect(slugs(limit: 100).size).to eq(described_class::MAX_LIMIT)
    expect(slugs(limit: 3).size).to eq(3)
    expect(slugs(limit: 0).size).to eq(1)
  end

  it "returns [] for a channel with no clips" do
    expect(described_class.new(channel: channel).call).to eq([])
  end

  it "reads the pool and its whole velocity series in two queries, whatever the clip count" do
    5.times { |i| climb(clip("m#{i}", views: 100 + i), from: 10, to: 100, hours: 5) }

    queries = 0
    counter = lambda do |_name, _start, _finish, _id, payload|
      queries += 1 if payload[:sql].to_s.start_with?("SELECT") && payload[:name] != "CACHE"
    end
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") do
      described_class.new(channel: channel).call
    end

    expect(queries).to eq(2)
  end
end
