# frozen_string_literal: true

require "rails_helper"

RSpec.describe ClipTranscript, type: :model do
  describe "validations" do
    subject { build(:clip_transcript) }

    it { is_expected.to validate_presence_of(:clip_id) }
    it { is_expected.to validate_presence_of(:broadcaster_id) }
    it { is_expected.to validate_inclusion_of(:status).in_array(described_class::STATUSES) }
    it { is_expected.to validate_numericality_of(:whisper_cost_cents).only_integer.is_greater_than_or_equal_to(0) }
  end

  describe "associations" do
    it { is_expected.to have_many(:clip_transcript_requests).dependent(:destroy) }
  end

  describe "#cache_hit?" do
    it "returns true when done + cached_at present" do
      transcript = build(:clip_transcript, :done)
      expect(transcript.cache_hit?).to be true
    end

    it "returns false when queued" do
      transcript = build(:clip_transcript, status: "queued", cached_at: nil)
      expect(transcript.cache_hit?).to be false
    end

    it "returns false when error" do
      transcript = build(:clip_transcript, :error)
      expect(transcript.cache_hit?).to be false
    end
  end

  describe "scopes" do
    it ".done filters by status='done'" do
      done = create(:clip_transcript, :done)
      create(:clip_transcript, status: "queued")
      expect(described_class.done).to contain_exactly(done)
    end

    it ".processing filters by status=queued or processing" do
      queued = create(:clip_transcript, status: "queued")
      processing = create(:clip_transcript, status: "processing")
      create(:clip_transcript, :done)
      expect(described_class.processing).to contain_exactly(queued, processing)
    end
  end
end
