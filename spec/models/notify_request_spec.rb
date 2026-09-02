# frozen_string_literal: true

require "rails_helper"

RSpec.describe NotifyRequest, type: :model do
  it { is_expected.to belong_to(:user).optional }

  it "normalizes email to stripped downcase" do
    record = described_class.create!(email: "  Fan@Example.COM ")
    expect(record.email).to eq("fan@example.com")
  end

  it "defaults source to lk_launch" do
    expect(described_class.new.source).to eq("lk_launch")
  end

  it "rejects the same interest twice, case-insensitively" do
    described_class.create!(email: "fan@example.com")
    expect(described_class.new(email: "FAN@example.com")).not_to be_valid
  end

  it "allows the same address to record a different plan (interest-level uniqueness, CR MF-1)" do
    described_class.create!(email: "fan@example.com", source: "pricing_interest", plan: "premium")
    second = described_class.new(email: "fan@example.com", source: "pricing_interest", plan: "business")
    expect(second).to be_valid
  end

  it "allows a launch-notify subscriber to also register plan interest" do
    described_class.create!(email: "fan@example.com") # screen 71, plan nil
    expect(described_class.new(email: "fan@example.com", source: "pricing_interest", plan: "pro")).to be_valid
  end

  it "rejects an unknown plan" do
    expect(described_class.new(email: "a@b.com", source: "pricing_interest", plan: "platinum")).not_to be_valid
  end

  it "rejects an invalid email format" do
    expect(described_class.new(email: "nope")).not_to be_valid
  end

  it "rejects an email over 255 characters (DB column limit)" do
    long = "#{"a" * 250}@example.com"
    expect(described_class.new(email: long)).not_to be_valid
  end

  it "rejects an unknown source" do
    expect(described_class.new(email: "a@b.com", source: "spam")).not_to be_valid
  end

  describe ".capture" do
    it "is idempotent per interest (normalized email + source + plan)" do
      expect do
        described_class.capture(email: "X@Y.com")
        described_class.capture(email: "x@y.com")
      end.to change(described_class, :count).by(1)
    end

    it "records a second row when the same address asks about another plan" do
      expect do
        described_class.capture(email: "buyer@example.com", source: "pricing_interest", plan: "premium")
        described_class.capture(email: "buyer@example.com", source: "pricing_interest", plan: "business")
      end.to change(described_class, :count).by(2)

      expect(described_class.where(email: "buyer@example.com").pluck(:plan)).to contain_exactly("premium", "business")
    end

    it "records plan interest from an address already captured on screen 71 (the MF-1 regression)" do
      described_class.capture(email: "early@example.com") # lk_launch, plan nil

      expect { described_class.capture(email: "early@example.com", source: "pricing_interest", plan: "pro") }
        .to change(described_class, :count).by(1)
    end

    it "keeps the first associated user on re-capture" do
      user = create(:user)
      described_class.capture(email: "a@b.com", user: user)
      described_class.capture(email: "a@b.com", user: nil)
      expect(described_class.find_by(email: "a@b.com").user).to eq(user)
    end

    it "returns the existing row on a pre-existing interest without raising (conflict branch)" do
      described_class.create!(email: "dup@example.com")
      expect { described_class.capture(email: "DUP@example.com") }
        .not_to change(described_class, :count)
    end
  end
end
