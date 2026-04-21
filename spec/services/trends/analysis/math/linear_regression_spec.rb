# frozen_string_literal: true

require "rails_helper"

RSpec.describe Trends::Analysis::Math::LinearRegression do
  describe ".fit" do
    it "returns nil for <2 points" do
      expect(described_class.fit([])).to be_nil
      expect(described_class.fit([ [ 1, 2 ] ])).to be_nil
    end

    it "returns nil when all x values identical (zero variance)" do
      expect(described_class.fit([ [ 3, 1 ], [ 3, 2 ], [ 3, 3 ] ])).to be_nil
    end

    it "fits a perfect line with slope 2, intercept 1" do
      result = described_class.fit([ [ 0, 1 ], [ 1, 3 ], [ 2, 5 ], [ 3, 7 ] ])

      expect(result.slope).to eq(2.0)
      expect(result.intercept).to eq(1.0)
      expect(result.r_squared).to eq(1.0)
      expect(result.residual_std).to eq(0.0)
      expect(result.n).to eq(4)
    end

    it "fits noisy data with R² < 1" do
      result = described_class.fit([ [ 0, 0 ], [ 1, 2 ], [ 2, 3 ], [ 3, 5 ], [ 4, 6 ] ])

      expect(result.slope).to be > 1.4
      expect(result.slope).to be < 1.6
      expect(result.r_squared).to be > 0.9
    end

    it "treats flat data (yy == 0, ss_res == 0) as perfect R²=1.0" do
      result = described_class.fit([ [ 0, 5 ], [ 1, 5 ], [ 2, 5 ], [ 3, 5 ] ])

      expect(result.slope).to eq(0.0)
      expect(result.r_squared).to eq(1.0)
    end

    it "confidence_band returns value/lower/upper around prediction" do
      result = described_class.fit([ [ 0, 0 ], [ 1, 1 ], [ 2, 2 ], [ 3, 3 ], [ 4, 5 ] ])
      band = result.confidence_band(5.0, 1.96)

      expect(band[:value]).to be > 4.0
      expect(band[:lower]).to be < band[:value]
      expect(band[:upper]).to be > band[:value]
    end
  end

  describe ".pearson_r" do
    it "returns 1.0 for perfectly positive correlation" do
      r = described_class.pearson_r([ [ 1, 1 ], [ 2, 2 ], [ 3, 3 ], [ 4, 4 ] ])
      expect(r).to eq(1.0)
    end

    it "returns -1.0 for perfectly negative correlation" do
      r = described_class.pearson_r([ [ 1, 4 ], [ 2, 3 ], [ 3, 2 ], [ 4, 1 ] ])
      expect(r).to eq(-1.0)
    end

    it "returns nil for zero variance in one series" do
      expect(described_class.pearson_r([ [ 1, 5 ], [ 2, 5 ], [ 3, 5 ] ])).to be_nil
    end

    it "returns nil for <2 points" do
      expect(described_class.pearson_r([])).to be_nil
      expect(described_class.pearson_r([ [ 1, 1 ] ])).to be_nil
    end

    it "rejects nil-containing pairs" do
      r = described_class.pearson_r([ [ 1, 1 ], [ nil, 2 ], [ 3, 3 ], [ 4, 4 ] ])
      expect(r).to eq(1.0)
    end

    it "clamps results to [-1, 1]" do
      # Create a borderline case — real math guarantees ≤1.0, but floating point can nudge.
      r = described_class.pearson_r([ [ 0.0, 0.0 ], [ 1.0, 1.0 ], [ 2.0, 2.0 ] ])
      expect(r).to be <= 1.0
      expect(r).to be >= -1.0
    end
  end
end
