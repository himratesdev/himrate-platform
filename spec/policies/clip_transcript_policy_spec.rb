# frozen_string_literal: true

require "rails_helper"

RSpec.describe ClipTranscriptPolicy do
  subject(:policy) { described_class.new(user, transcript) }

  let(:transcript) { build(:clip_transcript) }

  context "guest" do
    let(:user) { nil }

    it { expect(policy.create?).to be false }
    it { expect(policy.show?).to be false }
    it { expect(policy.index?).to be false }
  end

  context "Free user under 10/мес limit" do
    let(:user) { create(:user, tier: "free") }

    before do
      9.times { create(:clip_transcript_request, user: user) }
    end

    it "allows create" do
      expect(policy.create?).to be true
    end

    it "shows remaining = 1" do
      expect(policy.remaining_for).to eq(1)
    end

    it "denies create at 10th" do
      create(:clip_transcript_request, user: user)
      expect(policy.create?).to be false
    end

    it "denies index (Premium only)" do
      expect(policy.index?).to be false
    end
  end

  context "Premium user (premium_active=true)" do
    let(:user) { create(:user, tier: "premium", premium_active: true) }

    it "allows create unlimited" do
      20.times { create(:clip_transcript_request, user: user) }
      expect(policy.create?).to be true
    end

    it "shows infinite remaining" do
      expect(policy.remaining_for).to eq(Float::INFINITY)
    end

    it "allows index (by_broadcaster)" do
      expect(policy.index?).to be true
    end
  end

  context "Business tier" do
    let(:user) { create(:user, tier: "business") }

    it "allows create unlimited (inherits Premium permissions)" do
      20.times { create(:clip_transcript_request, user: user) }
      expect(policy.create?).to be true
    end
  end
end
