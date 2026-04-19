# frozen_string_literal: true

require "rails_helper"

RSpec.describe TrendsDailyAggregate do
  describe "associations" do
    it { is_expected.to belong_to(:channel) }
  end

  describe "validations" do
    subject { build(:trends_daily_aggregate) }

    it { is_expected.to be_valid }
    it { is_expected.to validate_presence_of(:date) }
    it { is_expected.to validate_presence_of(:schema_version) }

    it "validates uniqueness of date scoped to channel" do
      existing = create(:trends_daily_aggregate)
      dup = build(:trends_daily_aggregate, channel: existing.channel, date: existing.date)
      expect(dup).not_to be_valid
      expect(dup.errors[:channel_id]).to include("has already been taken")
    end

    it "allows same date for different channels" do
      first = create(:trends_daily_aggregate)
      second = build(:trends_daily_aggregate, date: first.date)
      expect(second).to be_valid
    end

    describe "Trust Index bounds (0..100)" do
      it "rejects ti_avg outside 0..100" do
        expect(build(:trends_daily_aggregate, ti_avg: 150)).not_to be_valid
        expect(build(:trends_daily_aggregate, ti_avg: -1)).not_to be_valid
      end

      it "rejects ti_min outside 0..100" do
        expect(build(:trends_daily_aggregate, ti_min: 150)).not_to be_valid
      end

      it "rejects ti_max outside 0..100" do
        expect(build(:trends_daily_aggregate, ti_max: 150)).not_to be_valid
      end

      it "accepts ti_std >= 0 (std не может быть отрицательным)" do
        expect(build(:trends_daily_aggregate, ti_std: 5.5)).to be_valid
      end

      it "rejects negative ti_std" do
        expect(build(:trends_daily_aggregate, ti_std: -1)).not_to be_valid
      end
    end

    describe "ERV percentages (0..100)" do
      it "rejects erv_min_percent outside 0..100" do
        expect(build(:trends_daily_aggregate, erv_min_percent: 150)).not_to be_valid
      end

      it "rejects erv_max_percent outside 0..100" do
        expect(build(:trends_daily_aggregate, erv_max_percent: -1)).not_to be_valid
      end
    end

    describe "CCV non-negative" do
      it "rejects negative ccv_avg" do
        expect(build(:trends_daily_aggregate, ccv_avg: -1)).not_to be_valid
      end

      it "rejects negative ccv_peak" do
        expect(build(:trends_daily_aggregate, ccv_peak: -1)).not_to be_valid
      end
    end

    describe "fractions (0..1)" do
      it "rejects discovery_phase_score outside 0..1" do
        expect(build(:trends_daily_aggregate, discovery_phase_score: 1.5)).not_to be_valid
      end

      it "rejects botted_fraction outside 0..1" do
        expect(build(:trends_daily_aggregate, botted_fraction: 1.5)).not_to be_valid
      end
    end

    describe "Pearson r (-1..1)" do
      it "accepts follower_ccv_coupling_r in [-1, 1]" do
        expect(build(:trends_daily_aggregate, follower_ccv_coupling_r: -0.5)).to be_valid
        expect(build(:trends_daily_aggregate, follower_ccv_coupling_r: 0.78)).to be_valid
      end

      it "rejects follower_ccv_coupling_r outside -1..1" do
        expect(build(:trends_daily_aggregate, follower_ccv_coupling_r: 1.5)).not_to be_valid
        expect(build(:trends_daily_aggregate, follower_ccv_coupling_r: -1.5)).not_to be_valid
      end
    end

    describe "streams_count non-negative" do
      it "rejects negative streams_count" do
        expect(build(:trends_daily_aggregate, streams_count: -1)).not_to be_valid
      end
    end

    describe "classification_at_end inclusion" do
      described_class::CLASSIFICATIONS.each do |cls|
        it "accepts canonical classification: #{cls}" do
          expect(build(:trends_daily_aggregate, classification_at_end: cls)).to be_valid
        end
      end

      it "rejects unknown classification" do
        expect(build(:trends_daily_aggregate, classification_at_end: "unknown_tier")).not_to be_valid
      end

      it "allows nil (classification может отсутствовать для empty days)" do
        expect(build(:trends_daily_aggregate, classification_at_end: nil)).to be_valid
      end
    end

    describe "schema_version enforcement" do
      it "accepts supported versions only" do
        expect(build(:trends_daily_aggregate, schema_version: 2)).to be_valid
      end

      it "rejects unsupported version (prevents drift)" do
        expect(build(:trends_daily_aggregate, schema_version: 99)).not_to be_valid
      end
    end
  end

  describe "scopes" do
    let(:channel) { create(:channel) }

    describe ".for_period" do
      it "returns aggregates within date range ordered by date asc" do
        a3 = create(:trends_daily_aggregate, channel: channel, date: 3.days.ago.to_date)
        a1 = create(:trends_daily_aggregate, channel: channel, date: 1.day.ago.to_date)
        _outside = create(:trends_daily_aggregate, channel: channel, date: 10.days.ago.to_date)

        result = described_class.for_period(channel, 5.days.ago.to_date, Date.current)
        expect(result).to eq([ a3, a1 ])
      end
    end

    describe ".with_tier_changes" do
      it "returns only days with tier_change_on_day=true" do
        with = create(:trends_daily_aggregate, :tier_change, channel: channel, date: 1.day.ago)
        _without = create(:trends_daily_aggregate, channel: channel, date: 2.days.ago)
        expect(described_class.with_tier_changes).to contain_exactly(with)
      end
    end

    describe ".with_discovery" do
      it "returns only days with discovery_phase_score IS NOT NULL" do
        with = create(:trends_daily_aggregate, :with_discovery, channel: channel, date: 1.day.ago)
        _without = create(:trends_daily_aggregate, channel: channel, date: 2.days.ago)
        expect(described_class.with_discovery).to contain_exactly(with)
      end
    end
  end
end
