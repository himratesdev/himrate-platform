# frozen_string_literal: true

require "rails_helper"

RSpec.describe PublicTop::Categories do
  def seed_category(game, channels:, date: 2.days.ago.to_date)
    channels.times do
      create(:trends_daily_aggregate, channel: create(:channel), date: date,
                                      categories: { game => 1 })
    end
  end

  before { Rails.cache.delete(described_class::CACHE_KEY) }

  it "lists categories with >= MIN_CHANNELS distinct channels, largest first, with slugs" do
    seed_category("Dota 2", channels: described_class::MIN_CHANNELS + 2)
    seed_category("Just Chatting", channels: described_class::MIN_CHANNELS)
    seed_category("Tiny Game", channels: 1) # below gate — excluded

    list = described_class.all
    expect(list.map { |c| c[:name] }).to eq([ "Dota 2", "Just Chatting" ])
    expect(list.first).to include(slug: "dota-2", channels: described_class::MIN_CHANNELS + 2)
  end

  it "counts a channel once per category even across multiple window days" do
    ch = create(:channel)
    3.times do |i|
      create(:trends_daily_aggregate, channel: ch, date: (i + 1).days.ago.to_date,
                                      categories: { "Dota 2" => 1 })
    end
    (described_class::MIN_CHANNELS - 1).times do
      create(:trends_daily_aggregate, channel: create(:channel), date: 2.days.ago.to_date,
                                      categories: { "Dota 2" => 1 })
    end

    expect(described_class.all.first[:channels]).to eq(described_class::MIN_CHANNELS)
  end

  it "ignores aggregates outside the 30-day window" do
    seed_category("Old Game", channels: described_class::MIN_CHANNELS,
                              date: (described_class::WINDOW_DAYS + 5).days.ago.to_date)

    expect(described_class.all).to be_empty
  end

  it "drops unsluggable (pure non-latin) categories instead of mangling them" do
    seed_category("Шахматы", channels: described_class::MIN_CHANNELS)

    expect(described_class.all).to be_empty
  end

  it "resolves a slug back to the exact category and returns nil for unknown slugs" do
    seed_category("Dota 2", channels: described_class::MIN_CHANNELS)

    expect(described_class.resolve("dota-2")).to include(name: "Dota 2")
    expect(described_class.resolve("nope")).to be_nil
  end
end
