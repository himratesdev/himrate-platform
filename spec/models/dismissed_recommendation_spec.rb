# frozen_string_literal: true

require "rails_helper"

RSpec.describe DismissedRecommendation do
  let(:user) { create(:user) }
  let(:channel) { create(:channel) }

  before do
    load Rails.root.join("db/seeds/health_score.rb") unless RecommendationTemplate.exists?
    HealthScoreSeeds.seed_recommendation_templates
  end

  it "validates rule_id format R-NN" do
    record = described_class.new(user: user, channel: channel, rule_id: "invalid")
    expect(record).not_to be_valid
    expect(record.errors[:rule_id]).to include(/must be in format R-NN/)

    record.rule_id = "R-01"
    expect(record).to be_valid
  end

  it "enforces uniqueness scope (user, channel, rule_id)" do
    described_class.create!(user: user, channel: channel, rule_id: "R-01")
    duplicate = described_class.new(user: user, channel: channel, rule_id: "R-01")
    expect(duplicate).not_to be_valid
  end

  it "auto-sets dismissed_at on create" do
    record = described_class.create!(user: user, channel: channel, rule_id: "R-02")
    expect(record.dismissed_at).to be_present
  end
end
