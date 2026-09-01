# frozen_string_literal: true

require "rails_helper"

RSpec.describe TrustIndex::V2::AxesBuilder do
  it "packages the 3 axes as separate fields — never averaged into one score" do
    axes = described_class.call(authenticity: 85.0, reputation: { band: "Стабильная", tier: "full" },
                                rho_obs: 0.009, cps: 72, authenticity_lo: 81.0, authenticity_hi: 89.0)
    expect(axes.authenticity).to eq({ value: 85.0, interval: { lo: 81.0, hi: 89.0 } })
    expect(axes.reputation).to eq({ tier: "full", band: "Стабильная", label_key: nil })
    expect(axes.engagement_context).to eq({ chat_share: 0.009, cps: 72 })
  end

  it "keeps CPS in the engagement axis, out of the authenticity number (BR-012)" do
    axes = described_class.call(authenticity: 40.0, reputation: nil, rho_obs: 0.002, cps: 10)
    expect(axes.engagement_context[:cps]).to eq(10)
    expect(axes.authenticity[:value]).to eq(40.0) # CPS did not fold into it
  end

  it "emits a null-field reputation axis when the Reputation domain has nothing (cold start)" do
    axes = described_class.call(authenticity: 40.0, reputation: nil, rho_obs: 0.002, cps: nil)
    expect(axes.reputation).to eq({ tier: nil, band: nil, label_key: nil })
    expect(axes.authenticity[:interval]).to eq({ lo: nil, hi: nil })
  end
end
