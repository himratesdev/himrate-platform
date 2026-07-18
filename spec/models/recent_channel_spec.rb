# frozen_string_literal: true

require "rails_helper"

RSpec.describe RecentChannel, type: :model do
  it { is_expected.to belong_to(:user) }
  it { is_expected.to belong_to(:channel) }

  describe ".track" do
    it "keeps one row per (user, channel) on re-open" do
      user = create(:user)
      channel = create(:channel)

      RecentChannel.track(user: user, channel: channel)
      RecentChannel.track(user: user, channel: channel)

      expect(RecentChannel.where(user: user, channel: channel).count).to eq(1)
    end

    it "bumps opened_at on re-open" do
      user = create(:user)
      channel = create(:channel)
      RecentChannel.track(user: user, channel: channel)
      RecentChannel.where(user: user, channel: channel).update_all(opened_at: 1.day.ago)

      bumped = RecentChannel.track(user: user, channel: channel)

      expect(bumped.opened_at).to be > 1.hour.ago
    end
  end
end
