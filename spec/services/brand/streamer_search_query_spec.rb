# frozen_string_literal: true

require "rails_helper"

RSpec.describe Brand::StreamerSearchQuery do
  # real_avg = ccv × erv/100. Explicit in-window dates (factory sequence(:date) leaks globally).
  def make_channel(login:, ccv:, erv:, ti: 85.0, classification: "trusted", game: "Dota 2", language: "ru", streams_count: 1, n_days: 3)
    ch = create(:channel, login: login)
    create(:stream, channel: ch, game_name: game, language: language, started_at: 1.hour.ago)
    n_days.times do |i|
      create(:trends_daily_aggregate, channel: ch, date: (i + 1).days.ago.to_date,
                                      ccv_avg: ccv, erv_avg_percent: erv, ti_avg: ti,
                                      classification_at_end: classification, categories: { game => 1 },
                                      streams_count: streams_count)
    end
    ch
  end

  def logins(result) = result[:results].map { |r| r[:login] }

  it "ranks by real audience (real=ccv×erv%) descending by default" do
    make_channel(login: "low",  ccv: 5_000, erv: 80.0)  # real 4000
    make_channel(login: "high", ccv: 10_000, erv: 90.0) # real 9000
    make_channel(login: "mid",  ccv: 8_000, erv: 75.0)  # real 6000

    result = described_class.new({}).call
    expect(logins(result)).to eq(%w[high mid low])
    expect(result[:total]).to eq(3)
    first = result[:results].first
    expect(first[:real_avg_viewers]).to eq(9_000)
    expect(first[:shown_avg_viewers]).to eq(10_000)
    expect(first[:real_avg_viewers]).to be < first[:shown_avg_viewers] # real bot-correction
    expect(first[:url]).to eq("https://twitch.tv/high")
    expect(result[:deferred]).to include("band_filter", "price")
  end

  it "filters by minimum real viewers" do
    make_channel(login: "big",   ccv: 10_000, erv: 90.0) # 9000
    make_channel(login: "small", ccv: 4_000, erv: 50.0)  # 2000

    result = described_class.new(min_real: "5000").call
    expect(logins(result)).to eq(%w[big])
    expect(result[:total]).to eq(1)
  end

  it "filters by category via the categories jsonb key" do
    make_channel(login: "dota", ccv: 5_000, erv: 80.0, game: "Dota 2")
    make_channel(login: "cs",   ccv: 6_000, erv: 80.0, game: "CS2")

    result = described_class.new(category: "CS2").call
    expect(logins(result)).to eq(%w[cs])
  end

  it "filters by latest stream language" do
    make_channel(login: "ru_ch", ccv: 5_000, erv: 80.0, language: "ru")
    make_channel(login: "en_ch", ccv: 6_000, erv: 80.0, language: "en")

    result = described_class.new(language: "en").call
    expect(logins(result)).to eq(%w[en_ch])
  end

  it "filters by a linked social platform (SA-2 footprint index)" do
    tg = make_channel(login: "tg_ch", ccv: 5_000, erv: 80.0)
    yt = make_channel(login: "yt_ch", ccv: 6_000, erv: 80.0)
    tg.social_links.create!(platform: "telegram", url: "https://t.me/tg_ch", analyzable: true)
    yt.social_links.create!(platform: "youtube", url: "https://youtube.com/c/yt", analyzable: true)

    result = described_class.new(platform: "telegram").call
    expect(logins(result)).to eq(%w[tg_ch])
  end

  it "ignores an unknown/non-analyzable platform value (unfiltered)" do
    make_channel(login: "any_ch", ccv: 5_000, erv: 80.0)

    result = described_class.new(platform: "myspace").call
    expect(logins(result)).to include("any_ch")
    expect(result[:deferred]).not_to include("platforms") # platform filter is now functional
  end

  it "filters by latest classification" do
    make_channel(login: "clean",  ccv: 5_000, erv: 80.0, classification: "trusted")
    make_channel(login: "sus",    ccv: 9_000, erv: 80.0, classification: "suspicious")

    result = described_class.new(classification: "trusted").call
    expect(logins(result)).to eq(%w[clean])
  end

  it "filters by streams-per-week frequency bucket" do
    # window 30d; spw = sum(streams_count)*7/30
    make_channel(login: "daily",   ccv: 5_000, erv: 80.0, streams_count: 10, n_days: 3) # 30 streams → 7/wk
    make_channel(login: "weekly",  ccv: 6_000, erv: 80.0, streams_count: 2,  n_days: 3) # 6 streams → 1.4/wk

    daily = described_class.new(frequency: "daily").call
    expect(logins(daily)).to eq(%w[daily])
    rare = described_class.new(frequency: "1_2").call
    expect(logins(rare)).to eq(%w[weekly])
  end

  it "paginates (page/per_page) with stable ordering" do
    5.times { |i| make_channel(login: "c#{i}", ccv: (i + 1) * 1_000, erv: 80.0) }

    page1 = described_class.new(per_page: "2", page: "1").call
    page2 = described_class.new(per_page: "2", page: "2").call
    expect(page1[:results].size).to eq(2)
    expect(page1[:total]).to eq(5)
    expect(page2[:page]).to eq(2)
    expect(logins(page1) & logins(page2)).to be_empty # disjoint pages
  end

  it "paginates deterministically even when the sort metric ties (stable channel_id tiebreaker)" do
    4.times { |i| make_channel(login: "tie#{i}", ccv: 5_000, erv: 80.0) } # all real_avg = 4000 (pure ties)

    orderings = Array.new(3) do
      p1 = described_class.new(per_page: "2", page: "1").call
      p2 = described_class.new(per_page: "2", page: "2").call
      all = logins(p1) + logins(p2)
      expect(all.uniq.size).to eq(4) # complete + disjoint across pages despite ties
      all
    end
    expect(orderings.uniq.size).to eq(1) # identical ordering across repeated requests
  end

  it "returns an empty result (not an error) when nothing matches" do
    make_channel(login: "only", ccv: 5_000, erv: 80.0)
    result = described_class.new(min_real: "99999999").call
    expect(result[:results]).to eq([])
    expect(result[:total]).to eq(0)
  end

  it "labels via the canonical ERV label map (not the stale design text)" do
    make_channel(login: "real", ccv: 10_000, erv: 95.0, ti: 95.0) # excellent band
    label = described_class.new({}).call[:results].first[:classification_label]
    expect(label).to eq("Аудитория реальная")
    expect(label).not_to eq("точно не бот")
  end

  it "excludes cold-start channels with no trends rows" do
    make_channel(login: "active", ccv: 5_000, erv: 80.0)
    create(:channel, login: "coldstart") # no trends

    expect(logins(described_class.new({}).call)).to eq(%w[active])
  end
end
