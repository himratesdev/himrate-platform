# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Team membership authorization", type: :policy do
  let(:channel) { create(:channel) }
  let(:business_owner) { create(:user, role: "viewer", tier: "business") }
  let(:team_member) { create(:user, role: "viewer", tier: "free") }

  before do
    create(:team_membership, user: team_member, team_owner: business_owner, status: "active")
  end

  it "team member inherits Business access for trust" do
    policy = TrustSnapshotPolicy.new(team_member, channel)
    expect(policy.full_access?).to be true
  end

  it "team member inherits Business access for streams" do
    policy = StreamPolicy.new(team_member, channel)
    expect(policy.index?).to be true
  end

  context "when team membership is removed" do
    before do
      TeamMembership.where(user: team_member).update_all(status: "removed")
    end

    it "team member loses Business access" do
      policy = TrustSnapshotPolicy.new(team_member, channel)
      expect(policy.full_access?).to be false
    end
  end

  context "when business owner subscription expires beyond grace" do
    before do
      business_owner.update!(tier: "free")
    end

    it "team member loses Business access" do
      policy = TrustSnapshotPolicy.new(team_member, channel)
      expect(policy.full_access?).to be false
    end
  end
end
