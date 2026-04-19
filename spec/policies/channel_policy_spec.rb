# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChannelPolicy, type: :policy do
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
    let(:subscription) { create(:subscription, user: user, is_active: true) }

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

    before { create(:auth_provider, user: user, provider: "twitch", provider_id: channel.twitch_id) }

    it { is_expected.to permit_action(:show) }
  end

  # TASK-039 Phase A2: FR-012/013/014 Trends-scoped predicates.
  describe "Trends predicates (FR-012/013/014)" do
    context "when guest" do
      let(:user) { nil }

      it { is_expected.to forbid_action(:view_trends_historical) }
      it { is_expected.to forbid_action(:view_365d_trends) }
      it { is_expected.to forbid_action(:view_peer_comparison) }
    end

    context "when free user without tracked channel" do
      let(:user) { create(:user, role: "viewer", tier: "free") }

      it { is_expected.to forbid_action(:view_trends_historical) }
      it { is_expected.to forbid_action(:view_365d_trends) }
      it { is_expected.to forbid_action(:view_peer_comparison) }
    end

    context "when premium with tracked channel" do
      let(:user) { create(:user, role: "viewer", tier: "premium") }
      let(:subscription) { create(:subscription, user: user, is_active: true) }

      before { create(:tracked_channel, user: user, channel: channel, subscription: subscription) }

      it { is_expected.to permit_action(:view_trends_historical) }
      it { is_expected.to forbid_action(:view_365d_trends) }
      it { is_expected.to permit_action(:view_peer_comparison) }
    end

    context "when premium without tracked channel" do
      let(:user) { create(:user, role: "viewer", tier: "premium") }

      it { is_expected.to forbid_action(:view_trends_historical) }
      it { is_expected.to forbid_action(:view_365d_trends) }
      it { is_expected.to forbid_action(:view_peer_comparison) }
    end

    context "when business user" do
      let(:user) { create(:user, role: "viewer", tier: "business") }

      it { is_expected.to permit_action(:view_trends_historical) }
      it { is_expected.to permit_action(:view_365d_trends) }
      it { is_expected.to permit_action(:view_peer_comparison) }
    end

    context "when streamer on own channel" do
      let(:user) { create(:user, role: "streamer", tier: "free") }

      before { create(:auth_provider, user: user, provider: "twitch", provider_id: channel.twitch_id) }

      it { is_expected.to permit_action(:view_trends_historical) }
      it { is_expected.to forbid_action(:view_365d_trends) }
      it { is_expected.to permit_action(:view_peer_comparison) }
    end

    context "when streamer on a different channel" do
      let(:user) { create(:user, role: "streamer", tier: "free") }
      let(:other_channel) { create(:channel) }

      before { create(:auth_provider, user: user, provider: "twitch", provider_id: other_channel.twitch_id) }

      it { is_expected.to forbid_action(:view_trends_historical) }
      it { is_expected.to forbid_action(:view_365d_trends) }
      it { is_expected.to forbid_action(:view_peer_comparison) }
    end
  end
end
