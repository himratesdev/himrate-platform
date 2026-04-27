# frozen_string_literal: true

require "rails_helper"

RSpec.describe AutoRemediationLog, type: :model do
  let(:base_attrs) do
    {
      destination: "production",
      accessory: "redis",
      triggered_at: Time.current,
      result: "triggered",
      attempt_number: 1
    }
  end

  describe "validations" do
    it "is valid with required fields" do
      expect(described_class.new(base_attrs)).to be_valid
    end

    %i[destination accessory triggered_at result attempt_number].each do |attr|
      it "requires #{attr}" do
        expect(described_class.new(base_attrs.merge(attr => nil))).not_to be_valid
      end
    end

    it "rejects invalid result enum" do
      expect(described_class.new(base_attrs.merge(result: "weird"))).not_to be_valid
    end

    it "requires attempt_number > 0" do
      expect(described_class.new(base_attrs.merge(attempt_number: 0))).not_to be_valid
    end
  end

  describe ".cool_down_active?" do
    it "true when triggered log exists в last 24h" do
      described_class.create!(base_attrs.merge(triggered_at: 1.hour.ago))
      expect(described_class.cool_down_active?(destination: "production", accessory: "redis")).to be true
    end

    it "false when last triggered older 24h" do
      described_class.create!(base_attrs.merge(triggered_at: 25.hours.ago))
      expect(described_class.cool_down_active?(destination: "production", accessory: "redis")).to be false
    end

    it "false когда result != triggered (skip_cooldown should not count)" do
      described_class.create!(base_attrs.merge(result: "skip_cooldown", triggered_at: 1.hour.ago))
      expect(described_class.cool_down_active?(destination: "production", accessory: "redis")).to be false
    end

    it "scoped per (destination, accessory)" do
      described_class.create!(base_attrs.merge(accessory: "db", triggered_at: 1.hour.ago))
      expect(described_class.cool_down_active?(destination: "production", accessory: "redis")).to be false
    end
  end

  describe ".max_attempts_exceeded?" do
    it "true когда >= 3 triggered events в last 72h" do
      3.times { |i| described_class.create!(base_attrs.merge(attempt_number: i + 1, triggered_at: i.hours.ago)) }
      expect(described_class.max_attempts_exceeded?(destination: "production", accessory: "redis")).to be true
    end

    it "false при < 3 triggered events" do
      2.times { |i| described_class.create!(base_attrs.merge(attempt_number: i + 1, triggered_at: i.hours.ago)) }
      expect(described_class.max_attempts_exceeded?(destination: "production", accessory: "redis")).to be false
    end

    it "ignores events older 72h" do
      described_class.create!(base_attrs.merge(triggered_at: 73.hours.ago))
      described_class.create!(base_attrs.merge(triggered_at: 80.hours.ago, attempt_number: 2))
      described_class.create!(base_attrs.merge(triggered_at: 90.hours.ago, attempt_number: 3))
      expect(described_class.max_attempts_exceeded?(destination: "production", accessory: "redis")).to be false
    end
  end

  describe ".disabled_for?" do
    it "true когда any log carries disabled_at" do
      described_class.create!(base_attrs.merge(result: "auto_disabled", disabled_at: Time.current))
      expect(described_class.disabled_for?(destination: "production", accessory: "redis")).to be true
    end

    it "false иначе" do
      described_class.create!(base_attrs)
      expect(described_class.disabled_for?(destination: "production", accessory: "redis")).to be false
    end
  end
end
