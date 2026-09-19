# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::Coordination" do
  let(:login) { "ring_focus" }
  let!(:group) do
    CoordinationGroup.create!(
      member_count: 3, accounts_shared: 40, events: 900, density: 1.0, window_days: 7,
      corroborated: false, corroborated_accounts: 0, corroborated_channels: 0,
      first_seen_at: 3.days.ago, computed_at: 1.hour.ago
    )
  end

  before do
    # :coordination_engine is a STAGING_ALL_FLAGS member — never auto-on in RAILS_ENV=test — so the
    # engine-on behaviour below has to switch it on explicitly. The flag-off contract is pinned in
    # its own context at the end of the file.
    Flipper.enable(:coordination_engine)
    %w[ring_focus ring_b ring_c].each_with_index do |l, i|
      group.members.create!(channel_login: l, ties: 40 - i, accounts: 30, events: 300)
    end
    group.edges.create!(a_login: "ring_b", b_login: "ring_focus", accounts_shared: 40, events: 400)
    group.accounts.create!(username: "bot_a", channels_in_group: 3, events: 30, max_concurrent: 3,
                           median_interval_sec: 30.0, interval_cv: 0.01, named_bot: true)
  end

  describe "GET /api/v1/channels/:login/coordination" do
    it "answers a guest — a coordination finding is a fact about a channel" do
      get "/api/v1/channels/#{login}/coordination"

      expect(response).to have_http_status(:ok)
      data = response.parsed_body["data"]
      expect(data["in_group"]).to be(true)
      expect(data["group"]["member_count"]).to eq(3)
      expect(data["group"]["members"].map { |m| m["login"] }).to eq(%w[ring_focus ring_b ring_c])
      expect(data["group"]["members"].first["is_focus"]).to be(true)
    end

    it "states the observation, not a verdict, until corroboration" do
      get "/api/v1/channels/#{login}/coordination"

      expect(response.parsed_body.dig("data", "group", "headline")).to eq("observation")
    end

    it "licenses the verdict wording only once the engine's evidence corroborates" do
      group.update!(corroborated: true, corroborated_accounts: 7, corroborated_channels: 2)

      get "/api/v1/channels/#{login}/coordination"

      expect(response.parsed_body.dig("data", "group", "headline")).to eq("verdict")
    end

    it "names its provenance — the accusation is built on the monitored archive only" do
      get "/api/v1/channels/#{login}/coordination"

      basis = response.parsed_body.dig("data", "group", "basis")
      expect(basis["source"]).to eq("monitored_chat")
      expect(basis["window_seconds"]).to eq(5)
      expect(basis["min_channels"]).to eq(3)
    end

    it "reports no ring for an unrelated channel instead of 404ing" do
      get "/api/v1/channels/somebody_else/coordination"

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["data"]).to eq("login" => "somebody_else", "in_group" => false)
    end

    it "is case-insensitive on the login" do
      get "/api/v1/channels/Ring_Focus/coordination"

      expect(response.parsed_body.dig("data", "in_group")).to be(true)
    end
  end

  describe "GET /api/v1/coordination/groups/:id" do
    it "returns the evidence panel: matrix edges plus the account table" do
      get "/api/v1/coordination/groups/#{group.id}?focus=#{login}"

      expect(response).to have_http_status(:ok)
      data = response.parsed_body["data"]
      expect(data["edges"].first).to include("a" => "ring_b", "b" => "ring_focus", "accounts_shared" => 40)
      account = data["accounts"].first
      expect(account).to include("username" => "bot_a", "named_bot" => true, "channels_in_group" => 3)
      expect(account["interval_cv"]).to eq(0.01)
    end

    it "404s an unknown group" do
      get "/api/v1/coordination/groups/#{SecureRandom.uuid}"

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body.dig("error", "code")).to eq("GROUP_NOT_FOUND")
    end
  end

  # The engine's bursts were Twitch Shared Chat relay, not a botnet. Switching the flag off must
  # darken every public read path even though the persisted rows are still there — same shapes a
  # ring-less channel and an unknown group already get, so no client has to change.
  context "when :coordination_engine is off" do
    before { Flipper.disable(:coordination_engine) }

    it "reports no ring for a channel whose group rows still exist" do
      get "/api/v1/channels/#{login}/coordination"

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["data"]).to eq("login" => login, "in_group" => false)
      expect(CoordinationGroup.for_channel_login(login)).to exist
    end

    it "does not serve the evidence panel of an existing group" do
      get "/api/v1/coordination/groups/#{group.id}?focus=#{login}"

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body.dig("error", "code")).to eq("GROUP_NOT_FOUND")
    end

    it "keeps the persisted rows untouched for the post-mortem" do
      expect { get "/api/v1/channels/#{login}/coordination" }
        .not_to change(CoordinationGroupMember, :count)
    end
  end
end
