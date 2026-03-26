# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChannelPolicy do
  subject { described_class.new(user, channel) }

  let(:channel) { create(:channel) }

  context "when guest (nil user)" do
    let(:user) { nil }

    it { is_expected.to forbid_action(:index) }
    it { is_expected.to permit_action(:show) }
    it { is_expected.to forbid_action(:create) }
    it { is_expected.to forbid_action(:destroy) }
  end

  context "when free user" do
    let(:user) { create(:user, role: "viewer", tier: "free") }

    it { is_expected.to permit_action(:index) }
    it { is_expected.to permit_action(:show) }
    it { is_expected.to permit_action(:create) }
    it { is_expected.to forbid_action(:destroy) }
  end

  context "when premium user with tracked channel" do
    let(:user) { create(:user, role: "viewer", tier: "premium") }
    let(:subscription) { create(:subscription, user: user, status: "active") }

    before { create(:tracked_channel, user: user, channel: channel, subscription: subscription) }

    it { is_expected.to permit_action(:index) }
    it { is_expected.to permit_action(:show) }
    it { is_expected.to permit_action(:create) }
    it { is_expected.to permit_action(:destroy) }
  end

  context "when business user" do
    let(:user) { create(:user, role: "viewer", tier: "business") }

    it { is_expected.to permit_action(:index) }
    it { is_expected.to permit_action(:show) }
    it { is_expected.to permit_action(:create) }
  end

  context "when streamer on own channel" do
    let(:user) { create(:user, role: "streamer", tier: "free") }

    before { create(:auth_provider, user: user, provider: "twitch", uid: channel.twitch_id) }

    it { is_expected.to permit_action(:show) }
  end
end
