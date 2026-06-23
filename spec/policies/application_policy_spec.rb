# frozen_string_literal: true

require "rails_helper"

# T1-060 DEC-3: the ApplicationPolicy duck-type seam is load-bearing — every policy spec
# and the ~8 direct ChannelPolicy.new(bare_user) call-sites pass a bare User, while
# authorize/pundit_user passes an Auth::AuthContext. Both must work; a User must never be
# mistaken for a context.
RSpec.describe ApplicationPolicy do
  let(:record) { Object.new }

  describe "#initialize duck-typing" do
    it "accepts a bare User and defaults the surface to extension" do
      user = build_stubbed(:user)
      policy = described_class.new(user, record)
      expect(policy.user).to eq(user)
      expect(policy.surface).to eq("extension")
    end

    it "unwraps an Auth::AuthContext into user + surface" do
      user = build_stubbed(:user)
      policy = described_class.new(Auth::AuthContext.new(user, "dashboard"), record)
      expect(policy.user).to eq(user)
      expect(policy.surface).to eq("dashboard")
    end

    it "defaults a blank surface in the context to extension" do
      policy = described_class.new(Auth::AuthContext.new(build_stubbed(:user), nil), record)
      expect(policy.surface).to eq("extension")
    end

    it "carries a guest (nil user) context without error" do
      policy = described_class.new(Auth::AuthContext.new(nil, "extension"), record)
      expect(policy.user).to be_nil
      expect(policy.send(:registered?)).to be false
    end
  end

  describe "surface + role predicates" do
    it "#dashboard_surface? is true only on the dashboard surface" do
      user = build_stubbed(:user)
      expect(described_class.new(Auth::AuthContext.new(user, "dashboard"), record).send(:dashboard_surface?)).to be true
      expect(described_class.new(user, record).send(:dashboard_surface?)).to be false
    end

    it "#streamer? reads is_streamer (not the legacy role scalar)" do
      expect(described_class.new(build_stubbed(:user, is_streamer: true), record).send(:streamer?)).to be true
      expect(described_class.new(build_stubbed(:user, is_streamer: false), record).send(:streamer?)).to be false
    end

    it "#brand? derives from business access" do
      expect(described_class.new(build_stubbed(:user, tier: "business"), record).send(:brand?)).to be true
      expect(described_class.new(create(:user, tier: "free"), record).send(:brand?)).to be false
    end
  end
end
