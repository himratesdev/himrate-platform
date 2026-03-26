# frozen_string_literal: true

require "rails_helper"

RSpec.describe BotChainPolicy, type: :policy do
  subject { described_class.new(user, channel) }

  let(:channel) { create(:channel) }

  context "when guest" do
    let(:user) { nil }

    it { is_expected.to permit_action(:show) }

    it "denies watchlist_access" do
      expect(subject.watchlist_access?).to be false
    end

    it "denies full_access" do
      expect(subject.full_access?).to be false
    end
  end

  context "when free user" do
    let(:user) { create(:user, role: "viewer", tier: "free") }

    it { is_expected.to permit_action(:show) }

    it "denies watchlist_access" do
      expect(subject.watchlist_access?).to be false
    end

    it "denies full_access" do
      expect(subject.full_access?).to be false
    end
  end

  context "when premium user with tracked channel" do
    let(:user) { create(:user, role: "viewer", tier: "premium") }
    let(:subscription) { create(:subscription, user: user, is_active: true) }

    before { create(:tracked_channel, user: user, channel: channel, subscription: subscription) }

    it { is_expected.to permit_action(:show) }

    it "allows watchlist_access" do
      expect(subject.watchlist_access?).to be true
    end

    it "denies full_access" do
      expect(subject.full_access?).to be false
    end
  end

  context "when business user" do
    let(:user) { create(:user, role: "viewer", tier: "business") }

    it { is_expected.to permit_action(:show) }

    it "allows watchlist_access" do
      expect(subject.watchlist_access?).to be true
    end

    it "allows full_access" do
      expect(subject.full_access?).to be true
    end
  end
end
