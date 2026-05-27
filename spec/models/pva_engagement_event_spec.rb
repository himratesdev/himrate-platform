# frozen_string_literal: true

require "rails_helper"

RSpec.describe PvaEngagementEvent, type: :model do
  subject { build(:pva_engagement_event) }

  it { is_expected.to belong_to(:user) }
  it { is_expected.to validate_presence_of(:event_type) }
  it { is_expected.to validate_inclusion_of(:event_type).in_array(described_class::EVENT_TYPES) }
  it { is_expected.to validate_inclusion_of(:source).in_array(described_class::SOURCES) }
  it { is_expected.to validate_length_of(:event_hash).is_equal_to(64) }
  it { is_expected.to validate_presence_of(:occurred_at) }

  describe ".compute_hash" do
    let(:args) do
      { user_id: "abc", event_type: "cheer", channel_id: "c1", occurred_at: Time.utc(2026, 5, 20, 12, 0, 0) }
    end

    it "returns deterministic 64-char SHA256 hex" do
      hash = described_class.compute_hash(**args)
      expect(hash).to match(/\A[0-9a-f]{64}\z/)
      expect(described_class.compute_hash(**args)).to eq(hash)
    end

    it "buckets occurred_at to the minute (idempotency window)" do
      a = described_class.compute_hash(**args.merge(occurred_at: Time.utc(2026, 5, 20, 12, 0, 15)))
      b = described_class.compute_hash(**args.merge(occurred_at: Time.utc(2026, 5, 20, 12, 0, 45)))
      expect(a).to eq(b)
    end
  end
end
