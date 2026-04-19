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
end
