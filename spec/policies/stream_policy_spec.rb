# frozen_string_literal: true

require "rails_helper"

RSpec.describe StreamPolicy do
  subject { described_class.new(user, channel) }

  let(:channel) { create(:channel) }

  context "when guest" do
    let(:user) { nil }

    it { is_expected.to forbid_action(:index) }
    it { is_expected.to forbid_action(:show) }
  end

  context "when free user within 18h post-stream window" do
    let(:user) { create(:user, role: "viewer", tier: "free") }

    before { create(:stream, channel: channel, started_at: 20.hours.ago, ended_at: 2.hours.ago) }

    it { is_expected.to permit_action(:index) }
    it { is_expected.to permit_action(:show) }
  end

  context "when free user after 18h window expired" do
    let(:user) { create(:user, role: "viewer", tier: "free") }

    before { create(:stream, channel: channel, started_at: 2.days.ago, ended_at: 20.hours.ago) }

    it { is_expected.to forbid_action(:index) }
  end

  context "when free user and next stream started (window closed)" do
    let(:user) { create(:user, role: "viewer", tier: "free") }

    before do
      create(:stream, channel: channel, started_at: 10.hours.ago, ended_at: 5.hours.ago)
      create(:stream, channel: channel, started_at: 2.hours.ago, ended_at: nil)
    end

    it { is_expected.to forbid_action(:index) }
  end

  context "when premium user with tracked channel" do
    let(:user) { create(:user, role: "viewer", tier: "premium") }
    let(:subscription) { create(:subscription, user: user, status: "active") }

    before { create(:tracked_channel, user: user, channel: channel, subscription: subscription) }

    it { is_expected.to permit_action(:index) }
    it { is_expected.to permit_action(:show) }
  end

  context "when premium user without tracked channel" do
    let(:user) { create(:user, role: "viewer", tier: "premium") }

    it { is_expected.to forbid_action(:index) }
  end

  context "when business user" do
    let(:user) { create(:user, role: "viewer", tier: "business") }

    it { is_expected.to permit_action(:index) }
    it { is_expected.to permit_action(:show) }
  end

  context "when streamer on own channel" do
    let(:user) { create(:user, role: "streamer", tier: "free") }

    before { create(:auth_provider, user: user, provider: "twitch", uid: channel.twitch_id) }

    it { is_expected.to permit_action(:index) }
  end
end
