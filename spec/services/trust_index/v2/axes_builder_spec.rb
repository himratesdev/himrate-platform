# frozen_string_literal: true

require "rails_helper"

RSpec.describe TrustIndex::V2::AxesBuilder do
  it "packages the 3 axes as separate fields — never averaged into one score" do
    axes = described_class.call(authenticity: 85.0, reputation: "Стабильная", rho_obs: 0.009, cps: 72)
    expect(axes.authenticity).to eq(85.0)
    expect(axes.reputation).to eq("Стабильная")
    expect(axes.engagement_context).to eq({ chat_share: 0.009, cps: 72 })
  end

  it "keeps CPS in the engagement axis, out of the authenticity number (BR-012)" do
    axes = described_class.call(authenticity: 40.0, reputation: nil, rho_obs: 0.002, cps: 10)
    expect(axes.engagement_context[:cps]).to eq(10)
    expect(axes.authenticity).to eq(40.0) # CPS did not fold into it
  end
end
