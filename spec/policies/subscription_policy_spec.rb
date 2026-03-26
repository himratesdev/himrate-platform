# frozen_string_literal: true

require "rails_helper"

RSpec.describe SubscriptionPolicy, type: :policy do
  context "when guest" do
    subject { described_class.new(nil, Subscription) }

    it { is_expected.to forbid_action(:index) }
    it { is_expected.to forbid_action(:create) }
    it { is_expected.to forbid_action(:destroy) }
  end

  context "when registered user" do
    let(:user) { create(:user, role: "viewer", tier: "free") }

    subject { described_class.new(user, Subscription) }

    it { is_expected.to permit_action(:index) }
    it { is_expected.to permit_action(:create) }
    it { is_expected.to permit_action(:destroy) }
  end
end
