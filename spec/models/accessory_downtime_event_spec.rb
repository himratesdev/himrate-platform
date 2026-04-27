# frozen_string_literal: true

require "rails_helper"

RSpec.describe AccessoryDowntimeEvent, type: :model do
  let(:base_attrs) do
    {
      destination: "production",
      accessory: "redis",
      started_at: 30.minutes.ago,
      source: "drift"
    }
  end

  describe "validations" do
    it "valid with required fields" do
      expect(described_class.new(base_attrs)).to be_valid
    end

    %i[destination accessory started_at source].each do |attr|
      it "requires #{attr}" do
        expect(described_class.new(base_attrs.merge(attr => nil))).not_to be_valid
      end
    end

    it "rejects invalid source enum" do
      expect(described_class.new(base_attrs.merge(source: "ufo"))).not_to be_valid
    end

    %w[drift restart health_fail rollback].each do |source|
      it "accepts source=#{source}" do
        expect(described_class.new(base_attrs.merge(source: source))).to be_valid
      end
    end
  end

  describe "before_save: compute_duration_seconds" do
    it "computes duration when ended_at is set" do
      record = described_class.new(base_attrs.merge(
        started_at: Time.current - 120, ended_at: Time.current
      ))
      record.save!
      expect(record.duration_seconds).to eq(120)
    end

    it "leaves duration_seconds nil when ended_at missing" do
      record = described_class.create!(base_attrs.merge(ended_at: nil))
      expect(record.duration_seconds).to be_nil
    end

    it "recomputes на subsequent save" do
      record = described_class.create!(base_attrs.merge(ended_at: nil))
      record.update!(ended_at: record.started_at + 75)
      expect(record.duration_seconds).to eq(75)
    end
  end

  describe ".recent" do
    it "returns events within window" do
      old_event = described_class.create!(base_attrs.merge(started_at: 40.days.ago))
      fresh_event = described_class.create!(base_attrs.merge(accessory: "db", started_at: 1.day.ago))
      expect(described_class.recent).to include(fresh_event)
      expect(described_class.recent).not_to include(old_event)
    end
  end
end
