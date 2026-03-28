# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Enum validations", type: :model do
  describe ScoreDispute do
    it "validates resolution_status inclusion" do
      dispute = build(:score_dispute, resolution_status: "invalid")
      expect(dispute).not_to be_valid
      expect(dispute.errors[:resolution_status]).to be_present
    end

    it "allows valid resolution_status" do
      ScoreDispute::RESOLUTION_STATUSES.each do |status|
        dispute = build(:score_dispute, resolution_status: status)
        expect(dispute).to be_valid, "Expected '#{status}' to be valid"
      end
    end
  end

  describe HealthScore do
    it "validates confidence_level inclusion" do
      score = build(:health_score, confidence_level: "invalid")
      expect(score).not_to be_valid
    end

    it "allows valid confidence_level" do
      HealthScore::CONFIDENCE_LEVELS.each do |level|
        score = build(:health_score, confidence_level: level)
        expect(score).to be_valid, "Expected '#{level}' to be valid"
      end
    end

    it "allows nil confidence_level" do
      score = build(:health_score, confidence_level: nil)
      expect(score).to be_valid
    end
  end

  describe Anomaly do
    it "validates anomaly_type inclusion" do
      anomaly = build(:anomaly, anomaly_type: "invalid")
      expect(anomaly).not_to be_valid
    end

    it "allows valid anomaly_type" do
      Anomaly::ANOMALY_TYPES.each do |type|
        anomaly = build(:anomaly, anomaly_type: type)
        expect(anomaly).to be_valid, "Expected '#{type}' to be valid"
      end
    end
  end

  describe TiSignal do
    it "validates signal_type inclusion" do
      signal = build(:ti_signal, signal_type: "invalid")
      expect(signal).not_to be_valid
    end

    it "allows valid signal_type" do
      TiSignal::SIGNAL_TYPES.each do |type|
        signal = build(:ti_signal, signal_type: type)
        expect(signal).to be_valid, "Expected '#{type}' to be valid"
      end
    end
  end

  describe Notification do
    it "validates type inclusion" do
      notification = build(:notification, type: "invalid")
      expect(notification).not_to be_valid
    end

    it "allows valid type" do
      Notification::NOTIFICATION_TYPES.each do |type|
        notification = build(:notification, type: type)
        expect(notification).to be_valid, "Expected '#{type}' to be valid"
      end
    end
  end
end
