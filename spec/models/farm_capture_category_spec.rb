# frozen_string_literal: true

require "rails_helper"

RSpec.describe FarmCaptureCategory do
  it "requires game_id + game_name and a non-negative integer viewer_floor" do
    row = described_class.new(game_id: "493057", game_name: "PUBG: BATTLEGROUNDS")
    expect(row).to be_valid

    expect(described_class.new(game_name: "x")).not_to be_valid
    expect(described_class.new(game_id: "1")).not_to be_valid
    expect(described_class.new(game_id: "1", game_name: "x", viewer_floor: -1)).not_to be_valid
  end

  it "enforces one row per game_id (strict category identity — never name matching)" do
    described_class.create!(game_id: "493057", game_name: "PUBG: BATTLEGROUNDS")
    dup = described_class.new(game_id: "493057", game_name: "PUBG again")

    expect(dup).not_to be_valid
    expect { dup.save!(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
  end

  it "language_filter returns nil for 'all languages' (nil or empty) and the list otherwise" do
    expect(described_class.new(languages: nil).language_filter).to be_nil
    expect(described_class.new(languages: []).language_filter).to be_nil
    expect(described_class.new(languages: %w[ru en]).language_filter).to eq(%w[ru en])
  end

  it ".enabled excludes disabled categories" do
    on = described_class.create!(game_id: "1", game_name: "on")
    described_class.create!(game_id: "2", game_name: "off", enabled: false)

    expect(described_class.enabled).to contain_exactly(on)
  end
end
