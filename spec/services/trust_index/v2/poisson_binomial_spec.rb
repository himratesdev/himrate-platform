# frozen_string_literal: true

require "rails_helper"

RSpec.describe TrustIndex::V2::PoissonBinomial do
  let(:z) { described_class::Z_P05 }

  it "returns Σp as the mean with a symmetric normal-approx P5/P95 interval" do
    r = described_class.call(Array.new(30, 0.9)) # mean 27, var 30·0.9·0.1 = 2.7 (interval fits [0,30])
    sd = Math.sqrt(2.7)
    expect(r.mean).to be_within(1e-9).of(27.0)
    expect(r.p5).to be_within(1e-6).of(27.0 - z * sd)
    expect(r.p95).to be_within(1e-6).of(27.0 + z * sd)
  end

  it "clamps the interval to [0, n] when the normal approx spills past the support" do
    r = described_class.call([ 0.5 ]) # mean 0.5, sd 0.5 → p5 would be negative, p95 > 1
    expect(r.p5).to eq(0.0)
    expect(r.p95).to eq(1.0)
  end

  it "handles an empty hard set (silent stream → F_hard = 0)" do
    r = described_class.call([])
    expect(r.mean).to eq(0.0)
    expect(r.p5).to eq(0.0)
    expect(r.p95).to eq(0.0)
  end

  it "gives P5 < mean < P95 for a non-degenerate set (dispute-safe lower bound)" do
    r = described_class.call(Array.new(100, 0.8))
    expect(r.p5).to be < r.mean
    expect(r.mean).to be < r.p95
    expect(r.mean).to be_within(1e-9).of(80.0)
  end
end
