# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::Brand::Overlap", type: :request do
  let(:brand_user) { create(:user, :brand) }

  # Presence comes from the ClickHouse layer now (Chat::PresenceQuery); logins/usernames are
  # namespaced because that table is shared+append-only across examples.
  let(:login_a) { ns("aaa") }
  let(:login_b) { ns("bbb") }
  let(:alice) { ns("alice") }

  before do
    create(:channel, login: login_a)
    create(:channel, login: login_b)
    seed({ login_a => [ alice, ns("bob") ], login_b => [ alice, ns("carol") ] })
  end

  it "returns overlap for a brand user" do
    get "/api/v1/brand/overlap", params: { channels: "#{login_a},#{login_b}" }, headers: auth_headers(brand_user)

    expect(response).to have_http_status(:ok)
    body = response.parsed_body
    expect(body["unique_reach"]).to eq(3)             # alice bob carol
    expect(body["audience_basis"]).to eq("chat_presence")
    expect(body["pairwise"].first["shared"]).to eq(1) # alice
  end

  it "denies a non-brand user (403)" do
    get "/api/v1/brand/overlap", params: { channels: "#{login_a},#{login_b}" }, headers: auth_headers(create(:user))
    expect(response).to have_http_status(:forbidden)
  end

  it "rejects fewer than 2 channels (400)" do
    get "/api/v1/brand/overlap", params: { channels: login_a }, headers: auth_headers(brand_user)
    expect(response).to have_http_status(:bad_request)
    expect(response.parsed_body.dig("error", "code")).to eq("CHANNELS_REQUIRED")
  end

  it "returns 404 for an unknown login" do
    get "/api/v1/brand/overlap", params: { channels: "#{login_a},ghost_#{SecureRandom.hex(3)}" }, headers: auth_headers(brand_user)
    expect(response).to have_http_status(:not_found)
    expect(response.parsed_body.dig("error", "code")).to eq("CHANNEL_NOT_FOUND")
  end

  it "requires auth" do
    get "/api/v1/brand/overlap", params: { channels: "#{login_a},#{login_b}" }
    expect(response).to have_http_status(:unauthorized)
  end

  def auth_headers(user)
    { "Authorization" => "Bearer #{Auth::JwtService.encode_access(user.id)}" }
  end
end
