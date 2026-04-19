# frozen_string_literal: true

require "rails_helper"

RSpec.describe Channel, type: :model do
  describe "associations" do
    it { is_expected.to have_many(:streams).dependent(:destroy) }
    it { is_expected.to have_many(:tracked_channels).dependent(:destroy) }
    it { is_expected.to have_many(:users).through(:tracked_channels) }
    it { is_expected.to have_many(:trust_index_histories).dependent(:destroy) }
    it { is_expected.to have_many(:health_scores).dependent(:destroy) }
    it { is_expected.to have_one(:streamer_reputation).dependent(:destroy) }
    it { is_expected.to have_one(:channel_protection_config).dependent(:destroy) }
    it { is_expected.to have_many(:trends_daily_aggregates).dependent(:destroy) }
  end

  describe "validations" do
    it { is_expected.to validate_presence_of(:twitch_id) }
    it { is_expected.to validate_presence_of(:login) }
  end
end
