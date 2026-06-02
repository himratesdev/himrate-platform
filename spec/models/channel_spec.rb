# frozen_string_literal: true

require "rails_helper"

RSpec.describe Channel, type: :model do
  describe "associations" do
    it { is_expected.to have_many(:streams).dependent(:destroy) }
    it { is_expected.to have_many(:tracked_channels).dependent(:destroy) }
    it { is_expected.to have_many(:users).through(:tracked_channels) }
    it { is_expected.to have_many(:trust_index_histories).dependent(:destroy) }
    it { is_expected.to have_one(:streamer_reputation).dependent(:destroy) }
    it { is_expected.to have_one(:channel_protection_config).dependent(:destroy) }
    it { is_expected.to have_many(:trends_daily_aggregates).dependent(:delete_all) }
  end

  describe "validations" do
    it { is_expected.to validate_presence_of(:twitch_id) }
    it { is_expected.to validate_presence_of(:login) }
  end

  # PR7 (MLFE EPIC): assign_helix_metadata now extracts twitch_created_at from Helix /users
  # response so MaturitySignals can compute account_age_days_capped.
  describe "#assign_helix_metadata" do
    let(:channel) { create(:channel) }

    it "parses twitch_created_at from Helix `created_at` ISO string" do
      channel.assign_helix_metadata(
        "display_name" => "Foo", "broadcaster_type" => "partner",
        "created_at" => "2020-05-15T12:00:00Z"
      )
      expect(channel.twitch_created_at).to eq(Time.parse("2020-05-15T12:00:00Z"))
    end

    it "preserves existing twitch_created_at when Helix omits the field" do
      channel.update!(twitch_created_at: Time.parse("2018-01-01T00:00:00Z"))
      channel.assign_helix_metadata("display_name" => "Foo", "broadcaster_type" => "partner")
      expect(channel.twitch_created_at).to eq(Time.parse("2018-01-01T00:00:00Z"))
    end

    it "preserves existing twitch_created_at when Helix `created_at` is empty string" do
      channel.update!(twitch_created_at: Time.parse("2019-02-02T00:00:00Z"))
      channel.assign_helix_metadata("display_name" => "Foo", "created_at" => "")
      expect(channel.twitch_created_at).to eq(Time.parse("2019-02-02T00:00:00Z"))
    end

    it "stamps metadata_synced_at on every call" do
      freeze_time = Time.parse("2026-06-02T10:00:00Z")
      Timecop.freeze(freeze_time) do
        channel.assign_helix_metadata("display_name" => "Foo")
        expect(channel.metadata_synced_at).to eq(freeze_time)
      end
    end
  end
end
