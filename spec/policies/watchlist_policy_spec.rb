# frozen_string_literal: true

require "rails_helper"

RSpec.describe WatchlistPolicy do
  let(:channel) { create(:channel) }

  context "when guest" do
    subject { described_class.new(nil, Watchlist) }

    it { is_expected.to forbid_action(:index) }
    it { is_expected.to forbid_action(:create) }
  end

  context "when free user" do
    let(:user) { create(:user, role: "viewer", tier: "free") }

    subject { described_class.new(user, Watchlist) }

    it { is_expected.to permit_action(:index) }
    it { is_expected.to permit_action(:create) }
  end

  context "when free user destroys own watchlist" do
    let(:user) { create(:user, role: "viewer", tier: "free") }
    let(:watchlist) { create(:watchlist, user: user) }

    subject { described_class.new(user, watchlist) }

    it { is_expected.to permit_action(:destroy) }
  end

  context "when user tries to destroy another's watchlist" do
    let(:user) { create(:user, role: "viewer", tier: "free") }
    let(:other_user) { create(:user, role: "viewer", tier: "free") }
    let(:watchlist) { create(:watchlist, user: other_user) }

    subject { described_class.new(user, watchlist) }

    it { is_expected.to forbid_action(:destroy) }
  end
end
