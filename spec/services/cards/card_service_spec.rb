# frozen_string_literal: true

require "rails_helper"

RSpec.describe Cards::CardService do
  # Channel with `completed` ended streams (TIH + PSR each), `rep_rows` StreamerReputation rows,
  # and optionally a live (ended_at: nil) stream so channel.live? == true.
  def build_channel(completed: 12, rep_rows: 6, live: false)
    channel = create(:channel)
    completed.times do |i|
      ended = (completed - i).hours.ago
      stream = create(:stream, channel: channel, started_at: ended - 2.hours, ended_at: ended)
      create(:post_stream_report, stream: stream, ccv_avg: 4000, ccv_peak: 5000,
                                  duration_ms: 7_200_000, generated_at: ended)
      create(:trust_index_history, channel: channel, stream: stream,
                                   trust_index_score: 90, erv_percent: 91, ccv: 4200, calculated_at: ended)
    end
    rep_rows.times { |j| create(:streamer_reputation, channel: channel, calculated_at: (rep_rows - j).hours.ago) }
    create(:stream, channel: channel, started_at: 20.minutes.ago, ended_at: nil) if live
    channel
  end

  def ctx(user, surface)
    Auth::AuthContext.new(user, surface)
  end

  def card(channel, user:, surface:)
    described_class.new(channel: channel, context: ctx(user, surface)).call
  end

  let(:free) { create(:user, tier: "free") }

  def owner_of(channel)
    owner = create(:user, :streamer)
    create(:auth_provider, user: owner, provider: "twitch", provider_id: channel.twitch_id)
    owner
  end

  describe "free layers (1-3) for any viewer" do
    it "TC-1 guest (extension) → headline + reputation available; live_drill + paid not" do
      result = card(build_channel, user: nil, surface: "extension")
      expect(result[:layers][:headline][:available]).to be(true)
      expect(result[:layers][:reputation][:available]).to be(true)
      expect(result[:layers][:live_drill][:available]).to be(false)
      expect(result[:layers][:period_depth][:available]).to be(false)
      expect(result[:layers][:period_depth][:cta][:action]).to eq("open_dashboard")
    end

    it "TC-6 reputation layer == HistoryService (single source, not build_full)" do
      c = build_channel
      expect(card(c, user: free, surface: "extension")[:layers][:reputation][:data])
        .to eq(Reputation::HistoryService.cached_for(c))
    end

    it "guest on a LIVE channel → live_drill register CTA (funnel)" do
      ld = card(build_channel(live: true), user: nil, surface: "extension")[:layers][:live_drill]
      expect(ld[:available]).to be(false)
      expect(ld[:cta][:action]).to eq("register")
    end

    it "TC-2 free registered on LIVE channel → live_drill available" do
      expect(card(build_channel(live: true), user: free, surface: "extension")[:layers][:live_drill][:available]).to be(true)
    end
  end

  describe "paid layers (4-5) surface + role gating" do
    it "TC-3 dashboard free viewer → period_depth subscribe CTA (SUBSCRIPTION_REQUIRED)" do
      pd = card(build_channel, user: free, surface: "dashboard")[:layers][:period_depth]
      expect(pd[:available]).to be(false)
      expect(pd[:cta]).to eq(action: "subscribe", code: "SUBSCRIPTION_REQUIRED")
    end

    it "extension free viewer → period_depth open_dashboard CTA (NEVER subscribe)" do
      pd = card(build_channel, user: free, surface: "extension")[:layers][:period_depth]
      expect(pd[:available]).to be(false)
      expect(pd[:cta][:action]).to eq("open_dashboard")
    end

    it "TC-9 free viewer on LIVE channel (dashboard) → period_depth STILL unavailable (no live-leak)" do
      expect(card(build_channel(live: true), user: free, surface: "dashboard")[:layers][:period_depth][:available]).to be(false)
    end

    it "TC-4 dashboard owner → period_depth available with stats + recent_streams" do
      c = build_channel
      pd = card(c, user: owner_of(c), surface: "dashboard")[:layers][:period_depth]
      expect(pd[:available]).to be(true)
      expect(pd[:data]).to include(:stats, :recent_streams)
      expect(pd[:data][:stats]).to include(:total_streams)
    end

    it "TC-11 gate-then-assemble: non-owner period_depth carries NO data key" do
      pd = card(build_channel, user: free, surface: "dashboard")[:layers][:period_depth]
      expect(pd).not_to have_key(:data)
    end
  end

  it "TC-6b never leaks top-level / headline reputation_band (FR-6: no Trust(:full))" do
    result = card(build_channel, user: free, surface: "dashboard")
    expect(result).not_to have_key(:reputation_band)
    expect(result[:layers][:headline][:data]).not_to have_key(:reputation_band)
  end
end
