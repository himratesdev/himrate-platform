# frozen_string_literal: true

require "rails_helper"

RSpec.describe TrustIndex::V2::Deficit do
  it "returns the count of viewers unexplained by the honest baseline: max(0, V − EIHC/ρ)" do
    # V=5000, EIHC=45, ρ*=0.03 → 45/0.03 = 1500 explained → 3500 deficit (S3 silent farm)
    expect(described_class.call(5000, 45.0, 0.03)).to be_within(1e-6).of(3500.0)
  end

  it "clamps to 0 when observed engagement fully explains V (honest channel)" do
    # V=1000, EIHC=60, ρ_lo=0.05 → 60/0.05 = 1200 ≥ 1000 → no deficit (F_soft_lo≈0, honest by construction)
    expect(described_class.call(1000, 60.0, 0.05)).to eq(0.0)
  end

  it "is 0 for a degenerate/absent baseline ρ (never fabricates fraud)" do
    expect(described_class.call(1000, 10.0, 0)).to eq(0.0)
    expect(described_class.call(1000, 10.0, nil)).to eq(0.0)
  end
end
