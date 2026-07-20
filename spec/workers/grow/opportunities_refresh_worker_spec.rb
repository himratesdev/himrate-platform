# frozen_string_literal: true

require "rails_helper"

RSpec.describe Grow::OpportunitiesRefreshWorker do
  let(:helix) { instance_double(Twitch::HelixClient) }

  before do
    allow(Twitch::HelixClient).to receive(:new).and_return(helix)
    Rails.cache.delete(described_class::CACHE_KEY)
    Rails.cache.delete(described_class::PENDING_KEY)
  end

  def streams(counts)
    counts.map { |v| { "viewer_count" => v } }
  end

  it "ranks PO-fit games (few streamers + distributed viewers) above saturated/monopolized ones" do
    allow_any_instance_of(Grow::SteamNewReleases).to receive(:call).and_return([
      { steam_id: 1, name: "NicheGem" },     # 9 streamers, distributed → the PO profile
      { steam_id: 2, name: "MonopolyGame" }, # few streamers but top-1 took everything
      { steam_id: 3, name: "NoTwitch" }      # no Twitch category → skipped
    ])
    allow(helix).to receive(:get_game).with(name: "NicheGem").and_return({ "id" => "111", "name" => "NicheGem", "box_art_url" => "b" })
    allow(helix).to receive(:get_game).with(name: "MonopolyGame").and_return({ "id" => "222", "name" => "MonopolyGame", "box_art_url" => "b" })
    allow(helix).to receive(:get_game).with(name: "NoTwitch").and_return(nil)
    allow(helix).to receive(:get_streams_by_game).with(game_id: "111").and_return(streams([ 300, 280, 250, 240, 200, 180, 150, 120, 100 ]))
    allow(helix).to receive(:get_streams_by_game).with(game_id: "222").and_return(streams([ 5000, 20, 10 ]))

    described_class.new.perform

    cached = Rails.cache.read(described_class::CACHE_KEY)
    expect(cached["games"].size).to eq(2)
    expect(cached["games"].first["name"]).to eq("NicheGem")
    gem_row = cached["games"].first
    expect(gem_row["live_streamers"]).to eq(9)
    expect(gem_row["top1_share_pct"]).to be < 20
    expect(gem_row["is_steam_new_release"]).to be(true)
    expect(gem_row["growth_score"]).to be > cached["games"].last["growth_score"]
  end

  it "keeps the stale cache when Steam is down (never blanks the page)" do
    Rails.cache.write(described_class::CACHE_KEY, { "games" => [ { "name" => "old" } ] })
    allow_any_instance_of(Grow::SteamNewReleases).to receive(:call).and_return([])

    described_class.new.perform
    expect(Rails.cache.read(described_class::CACHE_KEY)["games"].first["name"]).to eq("old")
  end

  it "skips categories with zero live demand and clears the pending marker" do
    Rails.cache.write(described_class::PENDING_KEY, true)
    allow_any_instance_of(Grow::SteamNewReleases).to receive(:call).and_return([ { steam_id: 9, name: "DeadGame" } ])
    allow(helix).to receive(:get_game).and_return({ "id" => "999", "name" => "DeadGame" })
    allow(helix).to receive(:get_streams_by_game).and_return([])

    described_class.new.perform
    expect(Rails.cache.read(described_class::CACHE_KEY)).to be_nil
    expect(Rails.cache.exist?(described_class::PENDING_KEY)).to be(false)
  end
end
