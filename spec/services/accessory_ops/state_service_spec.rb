# frozen_string_literal: true

require "rails_helper"

RSpec.describe AccessoryOps::StateService do
  describe ".find_or_create" do
    it "creates record при first call с current_image=previous_image" do
      record = described_class.find_or_create(destination: "staging", accessory: "redis", current_image: "redis:7.4-alpine")
      expect(record).to be_persisted
      expect(record.current_image).to eq("redis:7.4-alpine")
      expect(record.previous_image).to eq("redis:7.4-alpine")
    end

    it "returns existing record не пересоздавая" do
      AccessoryState.create!(destination: "staging", accessory: "redis", current_image: "redis:7.4-alpine")
      expect {
        described_class.find_or_create(destination: "staging", accessory: "redis")
      }.not_to change(AccessoryState, :count)
    end
  end

  describe ".update_after_health_check" do
    it "creates record когда отсутствует" do
      expect {
        described_class.update_after_health_check(
          destination: "staging", accessory: "db", image: "postgres:16", status: "healthy"
        )
      }.to change(AccessoryState, :count).by(1)

      record = AccessoryState.find_by(destination: "staging", accessory: "db")
      expect(record.current_image).to eq("postgres:16")
      expect(record.previous_image).to eq("postgres:16")
      expect(record.last_health_status).to eq("healthy")
    end

    it "swaps current↔previous когда image changes" do
      AccessoryState.create!(
        destination: "staging", accessory: "redis",
        current_image: "redis:7.2-alpine", previous_image: "redis:7.0-alpine"
      )
      record = described_class.update_after_health_check(
        destination: "staging", accessory: "redis", image: "redis:7.4-alpine", status: "healthy"
      )
      expect(record.previous_image).to eq("redis:7.2-alpine")
      expect(record.current_image).to eq("redis:7.4-alpine")
    end

    it "не свопит previous когда image unchanged" do
      AccessoryState.create!(
        destination: "staging", accessory: "redis",
        current_image: "redis:7.4-alpine", previous_image: "redis:7.0-alpine"
      )
      record = described_class.update_after_health_check(
        destination: "staging", accessory: "redis", image: "redis:7.4-alpine", status: "healthy"
      )
      expect(record.previous_image).to eq("redis:7.0-alpine")
      expect(record.current_image).to eq("redis:7.4-alpine")
    end

    it "updates last_health_check_at + last_health_status" do
      AccessoryState.create!(destination: "staging", accessory: "redis", current_image: "redis:7.4-alpine")
      freeze_time = Time.utc(2026, 4, 27, 12, 0, 0)
      Timecop.freeze(freeze_time) do
        record = described_class.update_after_health_check(
          destination: "staging", accessory: "redis", image: "redis:7.4-alpine", status: "unhealthy"
        )
        expect(record.last_health_check_at).to be_within(1.second).of(freeze_time)
        expect(record.last_health_status).to eq("unhealthy")
      end
    rescue NameError
      # Timecop not available — fallback simpler assertion
      record = described_class.update_after_health_check(
        destination: "staging", accessory: "redis", image: "redis:7.4-alpine", status: "unhealthy"
      )
      expect(record.last_health_status).to eq("unhealthy")
      expect(record.last_health_check_at).to be_present
    end
  end

  describe ".previous_image" do
    it "returns previous_image когда state exists" do
      AccessoryState.create!(
        destination: "staging", accessory: "redis",
        current_image: "redis:7.4-alpine", previous_image: "redis:7.2-alpine"
      )
      expect(described_class.previous_image(destination: "staging", accessory: "redis")).to eq("redis:7.2-alpine")
    end

    it "returns nil когда state missing" do
      expect(described_class.previous_image(destination: "staging", accessory: "redis")).to be_nil
    end
  end
end
