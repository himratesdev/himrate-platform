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
end
