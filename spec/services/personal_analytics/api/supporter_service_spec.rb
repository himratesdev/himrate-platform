# frozen_string_literal: true

require "rails_helper"

RSpec.describe PersonalAnalytics::Api::SupporterService do
  let(:user) { create(:user) }

  it "returns empty supporters when none computed" do
    expect(described_class.new(user: user).call[:data][:supporters]).to eq([])
  end

  it "returns tier + tenure_months and HIDES composite_score (BR-006 — категория, не число)" do
    create(:pva_supporter_status, user: user, twitch_channel_id: "555", twitch_login: "xqc",
      tier: "devoted", composite_score: 44.0)
    create(:channel_tenure, user: user, twitch_channel_id: "555", months: 18)

    supporter = described_class.new(user: user).call[:data][:supporters].first

    expect(supporter[:tier]).to eq("devoted")
    expect(supporter[:tenure_months]).to eq(18)
    expect(supporter).not_to have_key(:composite_score)
  end
end
