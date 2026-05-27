# frozen_string_literal: true

require "rails_helper"

RSpec.describe UserPrivacySetting, type: :model do
  subject { build(:user_privacy_setting) }

  it { is_expected.to belong_to(:user) }

  describe "#streamer_facing_alias" do
    it "returns a stable User_<4hex> pseudonym (GDPR — shown until display_name_visible)" do
      setting = described_class.new(user_id: "abc")
      expect(setting.streamer_facing_alias).to match(/\AUser_[0-9a-f]{4}\z/)
      expect(setting.streamer_facing_alias).to eq(described_class.new(user_id: "abc").streamer_facing_alias)
    end
  end
end
