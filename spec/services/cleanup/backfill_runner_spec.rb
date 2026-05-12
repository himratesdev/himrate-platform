# frozen_string_literal: true

require "rails_helper"

RSpec.describe Cleanup::BackfillRunner do
  let(:channel) { create(:channel) }
  let(:ended_old) { create(:stream, channel: channel, started_at: 100.days.ago, ended_at: 95.days.ago) }
  let(:cutoff) { 90.days.ago }

  describe ".run_tih (FR-013/039)" do
    it "dry-run returns 0 and deletes nothing" do
      intermediate = create(:trust_index_history, channel: channel, stream: ended_old, calculated_at: 96.days.ago)
      create(:trust_index_history, channel: channel, stream: ended_old, calculated_at: 95.days.ago)

      result = nil
      expect { result = described_class.run_tih(cutoff: cutoff, dry_run: true) }.to output(/DRY-RUN/).to_stdout
      expect(result).to eq(0)
      expect(TrustIndexHistory.exists?(intermediate.id)).to be true
    end

    it "actual run prunes intermediate TIH, preserves the final (conservation rule)" do
      intermediate = create(:trust_index_history, channel: channel, stream: ended_old, calculated_at: 96.days.ago)
      final = create(:trust_index_history, channel: channel, stream: ended_old, calculated_at: 95.days.ago)

      result = nil
      expect { result = described_class.run_tih(cutoff: cutoff, dry_run: false) }.to output(/Done: 1 intermediate/).to_stdout
      expect(result).to eq(1)
      expect(TrustIndexHistory.exists?(intermediate.id)).to be false
      expect(TrustIndexHistory.exists?(final.id)).to be true
    end

    it "applies SET LOCAL statement_timeout per batch" do
      create(:trust_index_history, channel: channel, stream: ended_old, calculated_at: 96.days.ago)
      create(:trust_index_history, channel: channel, stream: ended_old, calculated_at: 95.days.ago)
      allow(ApplicationRecord.connection).to receive(:execute).and_call_original

      described_class.run_tih(cutoff: cutoff, dry_run: false)

      expect(ApplicationRecord.connection).to have_received(:execute).with("SET LOCAL statement_timeout = '30s'").at_least(:once)
    end
  end

  describe ".run_table (FR-013/039)" do
    it "dry-run returns 0 and deletes nothing" do
      old = CcvSnapshot.create!(stream: ended_old, ccv_count: 1, timestamp: 95.days.ago)
      result = nil
      expect { result = described_class.run_table(model: CcvSnapshot, cutoff: cutoff, dry_run: true) }.to output(/DRY-RUN/).to_stdout
      expect(result).to eq(0)
      expect(CcvSnapshot.exists?(old.id)).to be true
    end

    it "actual run deletes rows older than the cutoff" do
      old = CcvSnapshot.create!(stream: ended_old, ccv_count: 1, timestamp: 95.days.ago)
      recent = CcvSnapshot.create!(stream: ended_old, ccv_count: 2, timestamp: 1.day.ago)
      result = nil
      expect { result = described_class.run_table(model: CcvSnapshot, cutoff: cutoff, dry_run: false) }.to output(/Done: 1 ccv_snapshots/).to_stdout
      expect(result).to eq(1)
      expect(CcvSnapshot.exists?(old.id)).to be false
      expect(CcvSnapshot.exists?(recent.id)).to be true
    end
  end
end
