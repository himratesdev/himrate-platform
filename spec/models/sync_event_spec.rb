# frozen_string_literal: true

require "rails_helper"

RSpec.describe SyncEvent, type: :model do
  describe "validations" do
    subject { build(:sync_event) }

    it { is_expected.to validate_presence_of(:event_type) }
    it { is_expected.to validate_inclusion_of(:event_type).in_array(described_class::EVENT_TYPES) }
    it { is_expected.to validate_presence_of(:event_hash) }
    it { is_expected.to validate_length_of(:event_hash).is_equal_to(64) }
    it { is_expected.to validate_presence_of(:synced_at) }
  end

  describe ".compute_hash" do
    it "returns 64-char SHA256 hex" do
      hash = described_class.compute_hash(
        user_id: SecureRandom.uuid,
        event_type: "stream_view",
        payload: { channel_id: "123" },
        synced_at: Time.utc(2026, 5, 20, 12, 0, 0)
      )
      expect(hash).to match(/\A[0-9a-f]{64}\z/)
    end

    it "is deterministic для same inputs" do
      args = {
        user_id: "abc",
        event_type: "stream_view",
        payload: { channel_id: "123" },
        synced_at: Time.utc(2026, 5, 20, 12, 0, 0)
      }
      expect(described_class.compute_hash(**args)).to eq(described_class.compute_hash(**args))
    end

    it "buckets синced_at к minute (same minute = same hash)" do
      hash1 = described_class.compute_hash(
        user_id: "abc", event_type: "stream_view", payload: {},
        synced_at: Time.utc(2026, 5, 20, 12, 0, 15)
      )
      hash2 = described_class.compute_hash(
        user_id: "abc", event_type: "stream_view", payload: {},
        synced_at: Time.utc(2026, 5, 20, 12, 0, 45)
      )
      expect(hash1).to eq(hash2)
    end
  end

  describe "uniqueness" do
    it "prevents duplicate (user_id, event_hash)" do
      first = create(:sync_event)
      dup = build(:sync_event, user: first.user, event_hash: first.event_hash)
      expect(dup).not_to be_valid
      expect(dup.errors[:event_hash]).to include("has already been taken")
    end
  end
end
