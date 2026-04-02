# frozen_string_literal: true

require "rails_helper"

RSpec.describe TrackingRequest do
  describe "validations" do
    it "is valid with user_id" do
      user = create(:user)
      expect(build(:tracking_request, user: user)).to be_valid
    end

    it "is valid with extension_install_id (guest)" do
      expect(build(:tracking_request, :guest)).to be_valid
    end

    it "is invalid without both user_id and extension_install_id" do
      request = build(:tracking_request, user: nil, extension_install_id: nil)
      expect(request).not_to be_valid
      expect(request.errors[:base]).to include(match(/identifier/i))
    end

    it "is invalid without channel_login" do
      request = build(:tracking_request, channel_login: nil)
      expect(request).not_to be_valid
    end

    it "normalizes channel_login to lowercase" do
      request = create(:tracking_request, channel_login: "XqCow")
      expect(request.channel_login).to eq("xqcow")
    end

    it "enforces uniqueness per user+channel" do
      user = create(:user)
      create(:tracking_request, user: user, channel_login: "shroud")
      dup = build(:tracking_request, user: user, channel_login: "Shroud")
      expect(dup).not_to be_valid
    end

    it "allows same channel from different users" do
      create(:tracking_request, user: create(:user), channel_login: "shroud")
      other = build(:tracking_request, user: create(:user), channel_login: "shroud")
      expect(other).to be_valid
    end

    it "validates status inclusion" do
      request = build(:tracking_request, status: "invalid")
      expect(request).not_to be_valid
    end
  end

  describe "scopes" do
    it ".pending returns only pending" do
      create(:tracking_request, user: create(:user), status: "pending")
      create(:tracking_request, :approved, user: create(:user), channel_login: "other")
      expect(described_class.pending.count).to eq(1)
    end

    it ".for_channel returns matching login" do
      create(:tracking_request, user: create(:user), channel_login: "shroud")
      create(:tracking_request, user: create(:user), channel_login: "xqc")
      expect(described_class.for_channel("shroud").count).to eq(1)
    end
  end
end
