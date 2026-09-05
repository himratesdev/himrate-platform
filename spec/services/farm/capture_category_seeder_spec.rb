# frozen_string_literal: true

require "rails_helper"

RSpec.describe Farm::CaptureCategorySeeder do
  let(:entries) do
    [
      { "game_id" => "493057", "game_name" => "PUBG: BATTLEGROUNDS" },
      { "game_id" => "509658", "game_name" => "Just Chatting", "languages" => %w[RU en] }
    ]
  end

  it "creates rows from the seed, lowercasing languages and defaulting floor/enabled" do
    result = described_class.call(entries: entries)

    expect(result.created).to eq(2)
    expect(result.updated).to eq(0)
    pubg = FarmCaptureCategory.find_by!(game_id: "493057")
    jc = FarmCaptureCategory.find_by!(game_id: "509658")
    expect(pubg.languages).to be_nil
    expect(pubg.viewer_floor).to eq(0)
    expect(pubg).to be_enabled
    expect(jc.languages).to eq(%w[ru en])
  end

  it "is idempotent: re-running updates in place and never duplicates a game_id" do
    described_class.call(entries: entries)
    entries[1]["languages"] = %w[en]

    result = described_class.call(entries: entries)

    expect(result.created).to eq(0)
    expect(result.updated).to eq(2)
    expect(FarmCaptureCategory.count).to eq(2)
    expect(FarmCaptureCategory.find_by!(game_id: "509658").languages).to eq(%w[en])
  end

  it "keeps an operator's enabled=false unless the seed says otherwise" do
    described_class.call(entries: entries)
    FarmCaptureCategory.find_by!(game_id: "493057").update!(enabled: false)

    described_class.call(entries: entries)

    expect(FarmCaptureCategory.find_by!(game_id: "493057")).not_to be_enabled
  end

  it "loads the committed seed file with the four launch categories (JC = ru+en only)" do
    seed = described_class.load_seed
    ids = seed.map { |e| e["game_id"] }

    expect(ids).to contain_exactly("493057", "32399", "29595", "509658")
    jc = seed.find { |e| e["game_id"] == "509658" }
    expect(jc["languages"]).to eq(%w[ru en])
    expect(seed.reject { |e| e["game_id"] == "509658" }.map { |e| e["languages"] }).to all(be_nil)
  end
end
