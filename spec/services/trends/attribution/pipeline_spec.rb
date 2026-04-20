# frozen_string_literal: true

require "rails_helper"

RSpec.describe Trends::Attribution::Pipeline do
  let(:channel) { create(:channel) }
  let(:stream) { create(:stream, channel: channel) }
  let(:anomaly) { create(:anomaly, stream: stream) }

  # Seed minimal AttributionSource rows (Phase A1 migration seeds their на staging/prod,
  # test env loads structure.sql без data).
  # CR N-1: 1:1 source-adapter mapping — RaidOrganicAdapter + RaidBotAdapter separate classes.
  # PG O-1: raid_attribution SignalConfigurations seeded (mirrors migration 20260420100005).
  before do
    %w[raid_organic_default_confidence raid_bot_fallback_confidence].each do |param|
      SignalConfiguration.find_or_create_by!(
        signal_type: "trust_index", category: "raid_attribution", param_name: param
      ) { |c| c.param_value = 0.8 }
    end

    AttributionSource.find_or_create_by!(source: "raid_organic") do |s|
      s.enabled = true
      s.priority = 10
      s.adapter_class_name = "Trends::Attribution::RaidOrganicAdapter"
      s.display_label_en = "Organic raid"
      s.display_label_ru = "Органический рейд"
    end
    AttributionSource.find_or_create_by!(source: "raid_bot") do |s|
      s.enabled = true
      s.priority = 11
      s.adapter_class_name = "Trends::Attribution::RaidBotAdapter"
      s.display_label_en = "Bot raid"
      s.display_label_ru = "Бот-рейд"
    end
    AttributionSource.find_or_create_by!(source: "unattributed") do |s|
      s.enabled = true
      s.priority = 999
      s.adapter_class_name = "Trends::Attribution::UnattributedFallback"
      s.display_label_en = "Unattributed"
      s.display_label_ru = "Не атрибутировано"
    end
  end

  describe ".call" do
    context "when only Unattributed matches" do
      it "creates single AnomalyAttribution row (fallback)" do
        expect {
          described_class.call(anomaly)
        }.to change(AnomalyAttribution, :count).by(1)

        attr = AnomalyAttribution.last
        expect(attr.source).to eq("unattributed")
        expect(attr.confidence).to eq(1.0)
      end
    end

    context "when bot raid matches" do
      before do
        create(:raid_attribution, stream: stream, is_bot_raid: true, bot_score: 0.9)
      end

      # 1:1 mapping: only RaidBotAdapter matches bot raid. RaidOrganicAdapter filter
      # returns nil (is_bot_raid=false required). Unattributed catch-all always.
      it "creates raid_bot + unattributed attributions" do
        described_class.call(anomaly)
        sources = AnomalyAttribution.where(anomaly_id: anomaly.id).pluck(:source)
        expect(sources).to contain_exactly("raid_bot", "unattributed")
      end
    end

    context "when organic raid matches" do
      before do
        create(:raid_attribution, stream: stream, is_bot_raid: false)
      end

      it "creates raid_organic + unattributed attributions" do
        described_class.call(anomaly)
        sources = AnomalyAttribution.where(anomaly_id: anomaly.id).pluck(:source)
        expect(sources).to contain_exactly("raid_organic", "unattributed")
      end
    end

    context "idempotent re-run" do
      it "does not duplicate rows на repeat invocation" do
        described_class.call(anomaly)
        first_count = AnomalyAttribution.where(anomaly_id: anomaly.id).count

        described_class.call(anomaly)
        expect(AnomalyAttribution.where(anomaly_id: anomaly.id).count).to eq(first_count)
      end
    end

    context "adapter raises exception" do
      before do
        allow(Trends::Attribution::RaidBotAdapter).to receive(:call).and_raise(StandardError, "boom")
      end

      it "continues pipeline, logs error, doesn't crash" do
        expect(Rails.logger).to receive(:error).at_least(:once)
        expect { described_class.call(anomaly) }.not_to raise_error

        # Unattributed fallback still created
        expect(AnomalyAttribution.find_by(anomaly_id: anomaly.id, source: "unattributed")).to be_present
      end
    end

    context "adapter class not found" do
      before do
        AttributionSource.find_or_create_by!(source: "igdb_release") do |s|
          s.enabled = true
          s.priority = 30
          s.adapter_class_name = "Trends::Attribution::NonExistentAdapter"
          s.display_label_en = "IGDB"
          s.display_label_ru = "IGDB"
        end
      end

      it "logs warning, continues pipeline" do
        expect(Rails.logger).to receive(:warn).at_least(:once)
        expect { described_class.call(anomaly) }.not_to raise_error
      end
    end
  end
end
