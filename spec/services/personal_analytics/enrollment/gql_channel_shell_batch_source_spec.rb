# frozen_string_literal: true

require "rails_helper"

RSpec.describe PersonalAnalytics::Enrollment::GqlChannelShellBatchSource do
  let(:user) { create(:user) }

  before do
    PersonalAnalytics::Enrollment::StateStore.initiate(user_id: user.id)
  end

  describe ".call" do
    it "returns done=0 если нет followed channels" do
      result = described_class.call(user.id)
      expect(result.status).to eq("done")
      expect(result.rows_affected).to eq(0)
    end

    it "skips PvaFollowedChannel rows с blank twitch_login" do
      create(:pva_followed_channel, user: user, twitch_channel_id: "111", twitch_login: nil, followed_at: 1.year.ago)
      stub_gql_response([])

      result = described_class.call(user.id)
      expect(result.status).to eq("done")
      expect(result.rows_affected).to eq(0)
    end

    it "enriches matched followed channels with avatar/color/display_name" do
      followed = create(:pva_followed_channel, user: user, twitch_channel_id: "12345",
        twitch_login: "shroud", followed_at: 1.year.ago)
      stub_gql_response([
        { "data" => { "userOrError" => { "id" => "12345", "login" => "shroud",
            "displayName" => "shroud", "primaryColorHex" => "00ADFF",
            "profileImageURL" => "https://example.com/shroud.jpg", "__typename" => "User" } } }
      ])

      result = described_class.call(user.id)
      expect(result.status).to eq("done")
      expect(result.rows_affected).to eq(1)
      followed.reload
      expect(followed.avatar_url).to eq("https://example.com/shroud.jpg")
      expect(followed.primary_color_hex).to eq("00ADFF")
    end

    it "skips entries без User __typename" do
      create(:pva_followed_channel, user: user, twitch_channel_id: "12345",
        twitch_login: "missing", followed_at: 1.year.ago)
      stub_gql_response([
        { "data" => { "userOrError" => { "__typename" => "UserDoesNotExist" } } }
      ])

      result = described_class.call(user.id)
      expect(result.rows_affected).to eq(0)
    end
  end

  def stub_gql_response(body)
    mock_response = instance_double(HTTP::Response, status: HTTP::Response::Status.new(200),
      body: instance_double(HTTP::Response::Body, to_s: body.to_json))
    allow(mock_response.status).to receive(:success?).and_return(true)
    allow(HTTP).to receive(:timeout).and_return(HTTP)
    allow(HTTP).to receive(:headers).and_return(HTTP)
    allow(HTTP).to receive(:post).and_return(mock_response)
  end
end
