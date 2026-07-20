# frozen_string_literal: true

require "rails_helper"

RSpec.describe SocialAnalytics::Telegram::TrustScore do
  def score(ratio:, cv: 0.2, posts: 20)
    described_class.call(view_sub_ratio: ratio, view_cv: cv, posts_on_page: posts)
  end

  it "affirms a healthy viewability channel as real (green, legal-safe)" do
    r = score(ratio: 23.7)
    expect(r[:score]).to be >= 90
    expect(r[:band_label]).to eq("Аудитория реальная")
    expect(r[:band_color]).to eq("green")
    expect(r[:confidence]).to eq("moderate")
    expect(r[:signals].first).to include(key: "view_sub_ratio", weight: "primary")
  end

  it "flags a channel whose views sit far below its subscriber base" do
    r = score(ratio: 4.0)
    expect(r[:score]).to be < 50
    expect(r[:band_color]).to eq("red")
    expect(r[:band_label]).to eq("Значительная аномалия онлайна")
  end

  it "puts a mid viewability channel in the neutral-anomaly band" do
    r = score(ratio: 11.0)
    expect(r[:band_color]).to eq("yellow")
    expect(r[:band_label]).to eq("Аномалия онлайна")
  end

  it "penalises unnaturally uniform views (weak secondary signal)" do
    natural = score(ratio: 16.0, cv: 0.2)[:score]
    uniform = score(ratio: 16.0, cv: 0.01)[:score]
    expect(uniform).to eq(natural - 8)
  end

  it "reports insufficient data below the post floor (no fabricated score)" do
    r = described_class.call(view_sub_ratio: nil, posts_on_page: 1)
    expect(r[:score]).to be_nil
    expect(r[:confidence]).to eq("insufficient")
    expect(r[:band_label]).to eq("Недостаточно данных")
  end
end
