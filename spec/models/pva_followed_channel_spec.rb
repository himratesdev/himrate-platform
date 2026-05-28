# frozen_string_literal: true

require "rails_helper"

RSpec.describe PvaFollowedChannel do
  let(:user) { create(:user) }

  subject(:record) do
    described_class.new(
      user: user,
      twitch_channel_id: "12345678",
      twitch_login: "shroud",
      display_name: "shroud",
      followed_at: 5.years.ago
    )
  end

  describe "validations" do
    it "is valid with required attributes" do
      expect(record).to be_valid
    end

    it "requires twitch_channel_id" do
      record.twitch_channel_id = nil
      expect(record).not_to be_valid
    end

    it "requires followed_at" do
      record.followed_at = nil
      expect(record).not_to be_valid
    end

    it "enforces uniqueness on twitch_channel_id scoped to user" do
      record.save!
      dup = described_class.new(user: user, twitch_channel_id: "12345678", followed_at: Time.current)
      expect(dup).not_to be_valid
    end

    it "allows same twitch_channel_id для different users" do
      record.save!
      other_user = create(:user)
      dup = described_class.new(user: other_user, twitch_channel_id: "12345678", followed_at: Time.current)
      expect(dup).to be_valid
    end
  end
end
