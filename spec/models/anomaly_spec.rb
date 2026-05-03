# frozen_string_literal: true

require "rails_helper"

RSpec.describe Anomaly, type: :model do
  describe "associations" do
    it { is_expected.to belong_to(:stream) }
    it { is_expected.to have_many(:anomaly_attributions).dependent(:delete_all) }
  end

  describe "validations" do
    it { is_expected.to validate_presence_of(:timestamp) }
    it { is_expected.to validate_presence_of(:anomaly_type) }

    it "validates anomaly_type inclusion" do
      record = build(:anomaly, anomaly_type: "invalid_type")
      expect(record).not_to be_valid
      expect(record.errors[:anomaly_type]).to include("is not included in the list")
    end

    it "accepts canonical anomaly_type" do
      # TASK-085 FR-019: bot_wave → anomaly_wave (ADR-085 D-2 legal-safe rename).
      expect(build(:anomaly, anomaly_type: "anomaly_wave")).to be_valid
    end

    it "accepts new TASK-085 enum values (ti_drop, erv_divergence)" do
      expect(build(:anomaly, anomaly_type: "ti_drop")).to be_valid
      expect(build(:anomaly, anomaly_type: "erv_divergence")).to be_valid
    end
  end
end
