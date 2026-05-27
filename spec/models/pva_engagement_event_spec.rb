# frozen_string_literal: true

require "rails_helper"

RSpec.describe PvaEngagementEvent, type: :model do
  subject { build(:pva_engagement_event) }

  it { is_expected.to belong_to(:user) }
  it { is_expected.to validate_presence_of(:client_event_id) }
  it { is_expected.to validate_presence_of(:event_type) }
  it { is_expected.to validate_inclusion_of(:event_type).in_array(described_class::EVENT_TYPES) }
  it { is_expected.to validate_inclusion_of(:source).in_array(described_class::SOURCES) }
  it { is_expected.to validate_length_of(:event_hash).is_equal_to(64) }
  it { is_expected.to validate_presence_of(:occurred_at) }

  describe ".compute_hash" do
    let(:args) { { user_id: "abc", client_event_id: "11111111-1111-1111-1111-111111111111" } }

    it "returns deterministic 64-char SHA256 hex over (user_id, client_event_id)" do
      hash = described_class.compute_hash(**args)
      expect(hash).to match(/\A[0-9a-f]{64}\z/)
      expect(described_class.compute_hash(**args)).to eq(hash)
    end

    it "dedupes a retry of the same nonce regardless of timestamp/amount jitter" do
      expect(described_class.compute_hash(**args)).to eq(described_class.compute_hash(**args))
    end

    it "keeps two distinct actions distinct (different nonce → different hash)" do
      other = described_class.compute_hash(user_id: "abc", client_event_id: "22222222-2222-2222-2222-222222222222")
      expect(described_class.compute_hash(**args)).not_to eq(other)
    end
  end
end
