# frozen_string_literal: true

require "rails_helper"

RSpec.describe TrustSnapshotPolicy do
  subject { described_class.new(user, channel) }

  let(:channel) { create(:channel) }

  context "when guest" do
    let(:user) { nil }

    it { is_expected.to permit_action(:show) }

    it "denies drill_down" do
      expect(subject.drill_down?).to be false
    end

    it "denies full_access" do
      expect(subject.full_access?).to be false
    end
  end

  context "when free user within 18h post-stream window" do
    let(:user) { create(:user, role: "viewer", tier: "free") }

    before { create(:stream, channel: channel, started_at: 20.hours.ago, ended_at: 2.hours.ago) }

    it { is_expected.to permit_action(:show) }

    it "allows drill_down" do
      expect(subject.drill_down?).to be true
    end
  end

  context "when free user after 18h window expired" do
    let(:user) { create(:user, role: "viewer", tier: "free") }

    before { create(:stream, channel: channel, started_at: 2.days.ago, ended_at: 20.hours.ago) }

    it "denies drill_down" do
      expect(subject.drill_down?).to be false
    end
  end

  context "when premium user with tracked channel" do
    let(:user) { create(:user, role: "viewer", tier: "premium") }
    let(:subscription) { create(:subscription, user: user, status: "active") }

    before { create(:tracked_channel, user: user, channel: channel, subscription: subscription) }

    it "allows full_access" do
      expect(subject.full_access?).to be true
    end
  end

  context "when business user" do
    let(:user) { create(:user, role: "viewer", tier: "business") }

    it "allows full_access" do
      expect(subject.full_access?).to be true
    end

    it "allows drill_down" do
      expect(subject.drill_down?).to be true
    end
  end

  context "when streamer on own channel" do
    let(:user) { create(:user, role: "streamer", tier: "free") }

    before { create(:auth_provider, user: user, provider: "twitch", uid: channel.twitch_id) }

    it "allows full_access" do
      expect(subject.full_access?).to be true
    end
  end

  context "when subscription in grace period (day 5)" do
    let(:user) { create(:user, role: "viewer", tier: "premium") }
    let(:subscription) { create(:subscription, user: user, status: "past_due", current_period_end: 5.days.ago) }

    before { create(:tracked_channel, user: user, channel: channel, subscription: subscription) }

    it "allows full_access within 7-day grace" do
      expect(subject.full_access?).to be true
    end
  end

  context "when subscription grace period expired (day 8)" do
    let(:user) { create(:user, role: "viewer", tier: "premium") }
    let(:subscription) { create(:subscription, user: user, status: "past_due", current_period_end: 8.days.ago) }

    before { create(:tracked_channel, user: user, channel: channel, subscription: subscription) }

    it "denies full_access after 7-day grace" do
      expect(subject.full_access?).to be false
    end
  end
end
