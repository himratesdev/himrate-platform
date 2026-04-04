# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Flipper Feature Flags" do
  # TC-001: all operational flags enabled after init
  describe "default flags" do
    %i[
      pundit_authorization
      bot_raid_chain
      compare_unlimited
      audience_overlap
      ad_calculator
      social_presence
      panel_tracking
      tracking_requests
      irc_monitor
      stream_monitor
      known_bots
      channel_discovery
      bot_scoring
      signal_compute
    ].each do |flag|
      it "#{flag} is enabled by default" do
        expect(Flipper.enabled?(flag)).to be true
      end
    end
  end

  # TC-002: unknown flag returns false
  describe "unknown flags" do
    it "returns false for non-existent flag" do
      expect(Flipper.enabled?(:completely_unknown_flag)).to be false
    end
  end

  # TC-003: pundit_enabled? uses Flipper
  describe "pundit_enabled? integration" do
    let(:controller_class) { Api::BaseController }

    it "pundit_enabled? returns true when flag enabled" do
      Flipper.enable(:pundit_authorization)
      controller = controller_class.new
      expect(controller.send(:pundit_enabled?)).to be true
    end

    it "pundit_enabled? returns false when flag disabled" do
      Flipper.disable(:pundit_authorization)
      controller = controller_class.new
      expect(controller.send(:pundit_enabled?)).to be false
    end
  end

  # TC-004: User has flipper_id
  describe "User Flipper::Identifier" do
    it "user responds to flipper_id" do
      user = create(:user)
      expect(user).to respond_to(:flipper_id)
      expect(user.flipper_id).to eq("User;#{user.id}")
    end
  end

  # TC-005: percentage gate
  describe "percentage gate" do
    it "enables for percentage of actors" do
      Flipper.enable_percentage_of_actors(:test_feature, 100)
      user = create(:user)
      expect(Flipper.enabled?(:test_feature, user)).to be true
    end

    it "disables when percentage is 0" do
      Flipper.enable_percentage_of_actors(:test_feature, 0)
      user = create(:user)
      expect(Flipper.enabled?(:test_feature, user)).to be false
    end
  end

  # TC-006: group gate
  describe "group gate" do
    before do
      Flipper.register(:business_users) { |actor| actor.respond_to?(:tier) && actor.tier == "business" }
      Flipper.register(:premium_users) { |actor| actor.respond_to?(:tier) && actor.tier == "premium" }
      Flipper.register(:streamers) { |actor| actor.respond_to?(:role) && actor.role == "streamer" }
    rescue Flipper::DuplicateGroup
      # Already registered in initializer
    end

    it "enables for business group" do
      Flipper.enable_group(:test_feature, :business_users)
      business_user = create(:user, tier: "business")
      free_user = create(:user, tier: "free")

      expect(Flipper.enabled?(:test_feature, business_user)).to be true
      expect(Flipper.enabled?(:test_feature, free_user)).to be false
    end

    it "enables for streamers group" do
      Flipper.enable_group(:test_feature, :streamers)
      streamer = create(:user, role: "streamer")
      viewer = create(:user, role: "viewer")

      expect(Flipper.enabled?(:test_feature, streamer)).to be true
      expect(Flipper.enabled?(:test_feature, viewer)).to be false
    end
  end

  # TC-009: no PUNDIT_ENABLED in code
  describe "PUNDIT_ENABLED removed" do
    it "base_controller does not reference ENV PUNDIT_ENABLED" do
      source = File.read(Rails.root.join("app/controllers/api/base_controller.rb"))
      expect(source).not_to include("PUNDIT_ENABLED")
    end
  end
end
