# frozen_string_literal: true

require "rails_helper"

RSpec.describe PersonalAnalytics::Reflection::ReflectionBuilder do
  let(:user) { create(:user, locale: "ru") }
  let(:monday) { Date.new(2026, 5, 18) } # Mon
  let(:sunday) { monday + 6 }            # Sun 2026-05-24

  def rollup(twitch_channel_id:, login:, date:, total_seconds:, sessions: 1, hour_histogram: { "20" => 1800 },
             first_seen_at: nil)
    create(:pva_view_rollup, user: user, twitch_channel_id: twitch_channel_id, twitch_login: login,
      date: date, total_seconds: total_seconds, session_count: sessions, hour_histogram: hour_histogram,
      first_seen_at: first_seen_at || date.to_time)
  end

  it "returns nil and writes no row when the week has no view rollups (edge #6 — empty week)" do
    expect(described_class.call(user.id, week_start: monday)).to be_nil
    expect(PvaWeeklyReflection.where(user_id: user.id)).to be_empty
  end

  it "composes the full RU narrative when total + top + new + peak are present" do
    rollup(twitch_channel_id: "1", login: "shroud", date: monday, total_seconds: 8 * 3600, sessions: 4,
      hour_histogram: { "20" => 8 * 3600 }, first_seen_at: monday.to_time - 365.days) # NOT new
    rollup(twitch_channel_id: "2", login: "newone", date: monday + 1, total_seconds: 3600,
      first_seen_at: monday.to_time) # new this week
    # prev week — для delta
    create(:pva_view_rollup, user: user, twitch_channel_id: "1", twitch_login: "shroud",
      date: monday - 5, total_seconds: 5 * 3600, first_seen_at: monday.to_time - 365.days)

    described_class.call(user.id, week_start: monday)

    row = PvaWeeklyReflection.find_by(user_id: user.id, week_start: monday)
    expect(row.reflection_source).to eq("template")
    expect(row.narrative).to include("9ч") # total = 8h + 1h
    expect(row.narrative).to include("больше прошлой") # delta_more
    expect(row.narrative).to include("shroud") # top
    expect(row.narrative).to include("1 новый канал") # new (RussianPlural :one)
    expect(row.narrative).to include("вечер") # peak period (hour 20)
  end

  it "renders the EN narrative when user.locale == 'en'" do
    user.update!(locale: "en")
    rollup(twitch_channel_id: "1", login: "shroud", date: monday, total_seconds: 3600)

    described_class.call(user.id, week_start: monday)

    expect(PvaWeeklyReflection.find_by(user_id: user.id).narrative).to include("on Twitch this week")
  end

  it "appends an anniversary moment when ChannelTenure.anniversary_at falls inside the week" do
    rollup(twitch_channel_id: "1", login: "shroud", date: monday, total_seconds: 3600)
    create(:channel_tenure, user: user, twitch_channel_id: "1", twitch_login: "shroud",
      months: 21, anniversary_at: monday + 3) # Thu in week

    described_class.call(user.id, week_start: monday)

    moments = PvaWeeklyReflection.find_by(user_id: user.id).moments
    cake = moments.find { |m| m["icon"] == "cake" }
    expect(cake["text"]).to include("shroud").and include("21-я месячная")
  end

  it "appends a new-channel moment (multi-visit text when sessions >= 2)" do
    rollup(twitch_channel_id: "9", login: "MoistCr1TiKaL", date: monday, total_seconds: 1800, sessions: 3,
      first_seen_at: monday.to_time)

    described_class.call(user.id, week_start: monday)

    rocket = PvaWeeklyReflection.find_by(user_id: user.id).moments.find { |m| m["icon"] == "rocket" }
    expect(rocket["text"]).to include("MoistCr1TiKaL").and include("3 раза")
  end

  it "appends a hype-train moment with pct vs baseline" do
    rollup(twitch_channel_id: "555", login: "xqc", date: monday, total_seconds: 3600)
    create(:pva_engagement_event, user: user, twitch_channel_id: "555", event_type: "hype_contribution",
      amount: 287, occurred_at: monday.to_time + 12.hours, source: "client_capture")
    # baseline (other users' hype on this channel) — нужен PvaEngagementEvent другого юзера
    other = create(:user)
    create(:pva_engagement_event, user: other, twitch_channel_id: "555", event_type: "hype_contribution",
      amount: 100, occurred_at: 10.days.ago, source: "client_capture")

    described_class.call(user.id, week_start: monday)

    trophy = PvaWeeklyReflection.find_by(user_id: user.id).moments.find { |m| m["icon"] == "trophy" }
    expect(trophy["text"]).to include("xqc").and include("287").and include("Hype Train")
  end

  it "is idempotent — recompute updates the row (unique by [user_id, week_start])" do
    rollup(twitch_channel_id: "1", login: "shroud", date: monday, total_seconds: 3600)
    described_class.call(user.id, week_start: monday)
    rollup(twitch_channel_id: "1", login: "shroud", date: monday + 1, total_seconds: 7200)

    described_class.call(user.id, week_start: monday)

    expect(PvaWeeklyReflection.where(user_id: user.id, week_start: monday).count).to eq(1)
  end

  it "normalizes a non-Monday week_start to the same ISO week's Monday" do
    rollup(twitch_channel_id: "1", login: "shroud", date: monday, total_seconds: 3600)

    described_class.call(user.id, week_start: sunday) # Sun → должен попасть в monday's row

    expect(PvaWeeklyReflection.find_by(user_id: user.id).week_start).to eq(monday)
  end
end
