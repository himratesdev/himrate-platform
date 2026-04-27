# frozen_string_literal: true

require "rails_helper"

RSpec.describe AccessoryDriftEvent, type: :model do
  let(:base_attrs) do
    {
      destination: "production",
      accessory: "redis",
      declared_image: "redis:7.4-alpine",
      runtime_image: "redis:7.2-alpine",
      detected_at: Time.current,
      status: "open"
    }
  end

  describe "validations" do
    it "is valid with required fields" do
      expect(described_class.new(base_attrs)).to be_valid
    end

    %i[destination accessory declared_image runtime_image detected_at].each do |attr|
      it "requires #{attr}" do
        record = described_class.new(base_attrs.merge(attr => nil))
        expect(record).not_to be_valid
        expect(record.errors[attr]).to be_present
      end
    end

    it "rejects invalid status" do
      expect(described_class.new(base_attrs.merge(status: "broken"))).not_to be_valid
    end

    it "requires resolved_at when status=resolved" do
      record = described_class.new(base_attrs.merge(status: "resolved", resolved_at: nil))
      expect(record).not_to be_valid
      expect(record.errors[:resolved_at]).to be_present
    end

    it "permits nil resolved_at when status=open" do
      expect(described_class.new(base_attrs.merge(resolved_at: nil))).to be_valid
    end
  end

  describe "scopes" do
    let!(:open_event) { described_class.create!(base_attrs) }
    let!(:resolved_event) do
      described_class.create!(base_attrs.merge(
        accessory: "db", status: "resolved", resolved_at: Time.current
      ))
    end

    it ".open_events returns only status=open" do
      expect(described_class.open_events).to contain_exactly(open_event)
    end

    it ".for_pair filters by destination + accessory" do
      expect(described_class.for_pair("production", "redis")).to contain_exactly(open_event)
    end
  end

  describe "#open?" do
    it "true when status=open" do
      expect(described_class.new(status: "open")).to be_open
    end

    it "false otherwise" do
      expect(described_class.new(status: "resolved")).not_to be_open
    end
  end

  describe "#mttr_seconds" do
    it "returns elapsed seconds when resolved" do
      detected = Time.current
      record = described_class.new(detected_at: detected, resolved_at: detected + 47.seconds)
      expect(record.mttr_seconds).to eq(47)
    end

    it "returns nil when not resolved" do
      expect(described_class.new(detected_at: Time.current, resolved_at: nil).mttr_seconds).to be_nil
    end
  end
end
