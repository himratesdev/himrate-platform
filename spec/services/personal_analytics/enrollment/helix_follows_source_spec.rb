# frozen_string_literal: true

require "rails_helper"

RSpec.describe PersonalAnalytics::Enrollment::HelixFollowsSource do
  let(:user) { create(:user) }
  let!(:auth_provider) do
    create(:auth_provider,
      user: user,
      provider: "twitch",
      provider_id: "241581609",
      access_token: "user_oauth_token",
      scopes: %w[user:read:email user:read:follows]
    )
  end

  before do
    PersonalAnalytics::Enrollment::StateStore.initiate(user_id: user.id)
    allow(PersonalAnalytics::Enrollment::StateStore).to receive(:update_source).and_call_original
  end

  describe ".call" do
    it "fails fast если scope не granted" do
      auth_provider.update!(scopes: %w[user:read:email]) # no user:read:follows

      result = described_class.call(user.id)
      expect(result.status).to eq("failed")
      expect(result.error_class).to eq("MissingFollowsScope")
    end

    it "fails fast если auth_provider absent" do
      auth_provider.destroy!

      result = described_class.call(user.id)
      expect(result.error_class).to eq("MissingAuthProvider")
    end

    it "upserts PvaFollowedChannel rows from Helix response" do
      mock_client = instance_double(Twitch::HelixUserFollowsClient)
      allow(Twitch::HelixUserFollowsClient).to receive(:new).and_return(mock_client)
      allow(mock_client).to receive(:followed_channels_pages).and_return([
        {
          "data" => [
            { "broadcaster_id" => "12345", "broadcaster_login" => "shroud",
              "broadcaster_name" => "shroud", "followed_at" => 5.years.ago.iso8601 }
          ]
        }
      ].each)

      result = described_class.call(user.id)
      expect(result.status).to eq("done")
      expect(result.rows_affected).to eq(1)
      expect(PvaFollowedChannel.where(user_id: user.id, twitch_channel_id: "12345")).to exist
    end

    it "handles ScopeError gracefully" do
      mock_client = instance_double(Twitch::HelixUserFollowsClient)
      allow(Twitch::HelixUserFollowsClient).to receive(:new).and_return(mock_client)
      allow(mock_client).to receive(:followed_channels_pages).and_raise(
        Twitch::HelixUserFollowsClient::ScopeError.new("denied")
      )

      result = described_class.call(user.id)
      expect(result.error_class).to eq("MissingFollowsScope")
    end
  end
end
