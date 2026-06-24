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
    it { is_expected.to forbid_action(:view_7d_trust_history) } # T1-060 FR-6
    it { is_expected.to permit_action(:show_reputation_history) } # T1-065: free trust-summary
  end

  context "when free user" do
    let(:user) { create(:user, role: "viewer", tier: "free") }

    it { is_expected.to permit_action(:index) }
    it { is_expected.to permit_action(:show) }
    it { is_expected.to permit_action(:create) }
    it { is_expected.to forbid_action(:destroy) }
    it { is_expected.to forbid_action(:view_7d_trust_history) } # T1-060 FR-6: 7d needs premium access
    it { is_expected.to permit_action(:show_reputation_history) } # T1-065: free trust-summary
  end

  context "when premium user with tracked channel" do
    let(:user) { create(:user, role: "viewer", tier: "premium") }
    let(:subscription) { create(:subscription, user: user, is_active: true) }

    before { create(:tracked_channel, user: user, channel: channel, subscription: subscription) }

    it { is_expected.to permit_action(:index) }
    it { is_expected.to permit_action(:show) }
    it { is_expected.to permit_action(:create) }
    it { is_expected.to permit_action(:destroy) }
    it { is_expected.to permit_action(:view_7d_trust_history) } # T1-060 FR-6
    it { is_expected.to permit_action(:show_reputation_history) } # T1-065: free trust-summary
  end

  context "when business user" do
    let(:user) { create(:user, role: "viewer", tier: "business") }

    it { is_expected.to permit_action(:index) }
    it { is_expected.to permit_action(:show) }
    it { is_expected.to permit_action(:create) }
    it { is_expected.to permit_action(:view_7d_trust_history) } # T1-060 FR-6
    it { is_expected.to permit_action(:show_reputation_history) } # T1-065: free trust-summary
  end

  context "when streamer on own channel" do
    let(:user) { create(:user, role: "streamer", tier: "free") }

    before { create(:auth_provider, user: user, provider: "twitch", provider_id: channel.twitch_id) }

    it { is_expected.to permit_action(:show) }
    it { is_expected.to permit_action(:view_7d_trust_history) } # T1-060 FR-6: owner via data-exchange
  end

  # TASK-A1 (philosophy-v2): FR-012/013 Trends-scoped predicates.
  describe "Trends predicates (FR-012/013)" do
    context "when guest" do
      let(:user) { nil }

      it { is_expected.to forbid_action(:view_trends_historical) }
      it { is_expected.to forbid_action(:view_365d_trends) }
    end

    context "when free user without tracked channel (offline, no post-stream window)" do
      let(:user) { create(:user, role: "viewer", tier: "free") }

      # Default channel has no streams → not live, no open window → still gated.
      it { is_expected.to forbid_action(:view_trends_historical) }
      it { is_expected.to forbid_action(:view_365d_trends) }
    end

    # T1-063 (v2 / Option A): viewer surface is free on the online slice.
    context "when free user on a LIVE channel" do
      let(:user) { create(:user, role: "viewer", tier: "free") }

      before { create(:stream, channel: channel, started_at: 10.minutes.ago, ended_at: nil) }

      it { is_expected.to permit_action(:view_trends_historical) }
      it { is_expected.to forbid_action(:view_365d_trends) } # 365d stays Business-only
    end

    context "when free user on an offline channel within the 18h post-stream window" do
      let(:user) { create(:user, role: "viewer", tier: "free") }

      before { create(:stream, channel: channel, started_at: 3.hours.ago, ended_at: 1.hour.ago) }

      it { is_expected.to permit_action(:view_trends_historical) }
    end

    context "when free user on an offline channel with an expired window (>18h)" do
      let(:user) { create(:user, role: "viewer", tier: "free") }

      before { create(:stream, channel: channel, started_at: 30.hours.ago, ended_at: 20.hours.ago) }

      it { is_expected.to forbid_action(:view_trends_historical) }
    end

    context "when premium with tracked channel" do
      let(:user) { create(:user, role: "viewer", tier: "premium") }
      let(:subscription) { create(:subscription, user: user, is_active: true) }

      before { create(:tracked_channel, user: user, channel: channel, subscription: subscription) }

      it { is_expected.to permit_action(:view_trends_historical) }
      it { is_expected.to forbid_action(:view_365d_trends) }
    end

    context "when premium without tracked channel" do
      let(:user) { create(:user, role: "viewer", tier: "premium") }

      it { is_expected.to forbid_action(:view_trends_historical) }
      it { is_expected.to forbid_action(:view_365d_trends) }
    end

    context "when business user" do
      let(:user) { create(:user, role: "viewer", tier: "business") }

      it { is_expected.to permit_action(:view_trends_historical) }
      it { is_expected.to permit_action(:view_365d_trends) }
    end

    context "when streamer on own channel" do
      let(:user) { create(:user, role: "streamer", tier: "free") }

      before { create(:auth_provider, user: user, provider: "twitch", provider_id: channel.twitch_id) }

      it { is_expected.to permit_action(:view_trends_historical) }
      it { is_expected.to forbid_action(:view_365d_trends) }
    end

    context "when streamer on a different channel" do
      let(:user) { create(:user, role: "streamer", tier: "free") }
      let(:other_channel) { create(:channel) }

      before { create(:auth_provider, user: user, provider: "twitch", provider_id: other_channel.twitch_id) }

      it { is_expected.to forbid_action(:view_trends_historical) }
      it { is_expected.to forbid_action(:view_365d_trends) }
    end
  end
end
