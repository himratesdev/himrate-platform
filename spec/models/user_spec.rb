# frozen_string_literal: true

require "rails_helper"

RSpec.describe User, type: :model do
  describe "associations" do
    it { is_expected.to have_many(:auth_providers).dependent(:destroy) }
    it { is_expected.to have_many(:subscriptions).dependent(:destroy) }
    it { is_expected.to have_many(:tracked_channels).dependent(:destroy) }
    it { is_expected.to have_many(:channels).through(:tracked_channels) }
    it { is_expected.to have_many(:watchlists).dependent(:destroy) }
    it { is_expected.to have_many(:sessions).dependent(:destroy) }
  end

  describe "validations" do
    it { is_expected.to validate_inclusion_of(:role).in_array(%w[viewer streamer]) }
    it { is_expected.to validate_inclusion_of(:tier).in_array(%w[free premium business]) }
  end

  describe "#streamer_twitch_ids (TASK-039 FR-039)" do
    let(:user) { create(:user, role: "streamer") }

    it "returns Set of twitch provider_ids" do
      create(:auth_provider, user: user, provider: "twitch", provider_id: "tw_42")
      expect(user.streamer_twitch_ids).to eq(Set.new([ "tw_42" ]))
    end

    it "excludes non-twitch providers" do
      create(:auth_provider, user: user, provider: "twitch", provider_id: "tw_42")
      create(:auth_provider, user: user, provider: "google", provider_id: "g_99")
      expect(user.streamer_twitch_ids).to eq(Set.new([ "tw_42" ]))
    end

    it "returns empty Set when no twitch provider" do
      expect(user.streamer_twitch_ids).to eq(Set.new)
    end

    it "memoizes — single query for repeated access" do
      create(:auth_provider, user: user, provider: "twitch", provider_id: "tw_42")
      user.streamer_twitch_ids
      query_count = 0
      counter = ->(*, payload) { query_count += 1 unless payload[:name]&.start_with?("SCHEMA") }
      ActiveSupport::Notifications.subscribed(counter, "sql.active_record") do
        5.times { user.streamer_twitch_ids }
      end
      expect(query_count).to eq(0)
    end
  end

  describe "T1-060 FR-3 role predicates" do
    it "#viewer? is always true for a registered user" do
      expect(build(:user, role: "viewer").viewer?).to be true
      expect(build(:user, :streamer).viewer?).to be true
    end

    it "#streamer? reflects is_streamer, not the legacy role scalar" do
      expect(build(:user, is_streamer: true).streamer?).to be true
      expect(build(:user, is_streamer: false).streamer?).to be false
    end

    it "#brand? derives from business access (tier), never drifts from a stored flag" do
      expect(build(:user, tier: "business").brand?).to be true
      expect(build(:user, tier: "free").brand?).to be false
    end

    it "#brand? is true for an active member of a business-tier team" do
      member = create(:user, tier: "free")
      owner = create(:user, tier: "business")
      create(:team_membership, user: member, team_owner: owner, status: "active")
      expect(member.brand?).to be true
    end

    it "supports multiple roles simultaneously" do
      user = build(:user, is_streamer: true, tier: "business")
      expect(user.roles).to contain_exactly(:viewer, :streamer, :brand)
    end

    it "#roles lists only the accumulated roles" do
      expect(build(:user, is_streamer: false, tier: "free").roles).to eq([ :viewer ])
      expect(build(:user, is_streamer: true, tier: "free").roles).to contain_exactly(:viewer, :streamer)
    end

    it "#has_role? delegates to the predicate" do
      user = build(:user, is_streamer: true, tier: "free")
      expect(user.has_role?(:streamer)).to be true
      expect(user.has_role?(:brand)).to be false
      expect(user.has_role?(:viewer)).to be true
    end

    it "#has_role? returns false for an unknown role (no NoMethodError)" do
      expect(build(:user).has_role?(:admin)).to be false
      expect(build(:user).has_role?("nonsense")).to be false
    end

    it "does NOT respond to surface/user (AuthContext duck-type cannot misroute it)" do
      user = build(:user)
      expect(user.respond_to?(:surface)).to be false
      expect(user.respond_to?(:user)).to be false
    end
  end
end
