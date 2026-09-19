# frozen_string_literal: true

require "rails_helper"

# Contract-finish (2026-09): the SRS §4A / extension-src/shared/api.ts alignment that unfreezes
# the T2 migration (ext PR #117) — nested axes on /trust + /card, drill decomposition fields,
# /erv headline promotion, band tooltip_key, string reason_codes, WS frame identity keys.
RSpec.describe "TI v2 contract finish", type: :request do
  let(:channel) { create(:channel) }
  let(:user_free) { create(:user, tier: "free") }
  let(:headers_free) { auth_headers(user_free) }

  before do
    allow(Flipper).to receive(:enabled?).and_call_original
    allow(Flipper).to receive(:enabled?).with(:ti_v2_engine).and_return(true)
  end

  let!(:stream) { create(:stream, channel: channel, started_at: 2.hours.ago, ended_at: nil) }
  let!(:tih) do
    create(:trust_index_history, :v2,
      channel: channel, stream: stream,
      band_row: 6, band_color: "amber", band_sub: "6b",
      reason_codes: [ { "code" => "CHATTER_QUALITY_LOW", "params" => {} } ],
      calculated_at: 1.minute.ago)
  end

  describe "GET /trust — nested axes + tooltip + string reason codes" do
    it "serves the SRS §4A headline shape" do
      get "/api/v1/channels/#{channel.id}/trust", headers: headers_free

      expect(response).to have_http_status(:ok)
      data = response.parsed_body["data"]

      # state + flat bridge + nested canon
      expect(data["state"]).to eq("live")
      expect(data["authenticity"]).to eq(72.0)
      expect(data.dig("axes", "authenticity", "value")).to eq(72.0)
      expect(data.dig("axes", "authenticity", "interval")).to eq({ "lo" => 68.0, "hi" => 76.0 })
      expect(data.dig("axes", "engagement_context", "chat_share")).to eq(0.23)
      expect(data.dig("axes", "engagement_context")).to have_key("cps")
      expect(data.dig("axes", "reputation")).to include("tier", "band")

      # band carries both keys; reason codes are bare strings on the headline
      expect(data.dig("band", "label_key")).to eq("band.amber_exceeds")
      expect(data.dig("band", "tooltip_key")).to eq("band.tooltip.amber_exceeds")
      expect(data["reason_codes"]).to eq([ "CHATTER_QUALITY_LOW" ])
      expect(data.dig("confirmed_anomaly", "shown")).to eq(false)
      expect(data["confirmed_anomaly"]).to have_key("provenance")
    end

    it "reports provenance for a hard-corroborated confirmed anomaly" do
      tih.update!(confirmed_anomaly: true, c_hard: true, band_row: 2, band_color: "yellow")

      get "/api/v1/channels/#{channel.id}/trust", headers: headers_free

      data = response.parsed_body["data"]
      expect(data.dig("confirmed_anomaly", "shown")).to eq(true)
      expect(data.dig("confirmed_anomaly", "provenance")).to eq("HARD_NAMED_FRACTION")
    end

    # DETECTION-AUDIT 2026-09-19 (CR iter-1 Nit-6): the other three plashka paths used to come back
    # confirmed_anomaly:true with provenance:nil — an accusation with no stated basis.
    describe "provenance for the paths that don't set c_hard/c_self" do
      def provenance_for(**flags)
        tih.update!(confirmed_anomaly: true, band_row: 2, band_color: "yellow", **flags)
        Trust::ShowService.new(channel: channel, view: :headline).call[:confirmed_anomaly]
      end

      it "names each path by the reason code the engine emits for it" do
        expect(provenance_for(c_hard_abs: true)[:provenance]).to eq("HARD_NAMED_FRACTION")
        expect(provenance_for(c_hard_abs: false, c_inflation: true)[:provenance]).to eq("INFLATION_EVENT_CORROBORATION")
        expect(provenance_for(c_inflation: false, c_pop: true)[:provenance]).to eq("POPULATION_CHAT_DEFICIT")
      end

      it "keeps named evidence ahead of the CCV-shape and population paths (ReasonCodeBuilder precedence)" do
        expect(provenance_for(c_hard: true, c_inflation: true, c_pop: true)[:provenance]).to eq("HARD_NAMED_FRACTION")
      end

      it "a row persisted before these columns existed (all NULL) keeps its old provenance" do
        expect(provenance_for(c_inflation: nil, c_hard_abs: nil, c_pop: nil)).to eq(shown: true, provenance: nil)
      end
    end
  end

  describe "Trust::ShowService :drill_down — decomposition fields (extension CardLiveDrillData)" do
    it "ships erv_breakdown with interval, reason_codes_detail objects and the signal_breakdown key" do
      payload = Trust::ShowService.new(channel: channel, view: :drill_down, user: user_free).call

      expect(payload[:erv_breakdown]).to eq(
        v: 5000, f_hard: 120.0, f_soft: 1400.0, f_hat: 1400.0,
        interval: { lo: 1200.0, hi: 1600.0 }
      )
      # label_key stays for clients translating against their own bundle (the extension); the
      # resolved title/text/tone landed with config/locales/reason.*.yml on 2026-09-09.
      expect(payload[:reason_codes_detail].first).to include(
        code: "CHATTER_QUALITY_LOW", label_key: "reason.chatter_quality_low", params: {}
      )
      expect(payload[:reason_codes_detail].first[:title]).to be_present
      expect(payload[:reason_codes_detail].first[:tone]).to eq("dim")
      # v2 rows persist no per-signal trace yet — the key is REQUIRED by the extension, [] not missing.
      expect(payload[:signal_breakdown]).to eq([])
    end
  end

  describe "GET /erv — headline promotion" do
    it "carries flat authenticity + confidence_marker in the HEADLINE view" do
      get "/api/v1/channels/#{channel.id}/erv", headers: headers_free

      expect(response).to have_http_status(:ok)
      data = response.parsed_body["data"]
      expect(data["authenticity"]).to eq(72.0)
      expect(data["confidence_marker"]).to eq("reliable")
      expect(data).not_to have_key("axes") # /erv stays FLAT per SRS Surface 2
    end
  end

  describe "Cards::CardService — headline + live_drill slices" do
    it "includes axes/state in headline and the drill decomposition in live_drill" do
      context = Auth::AuthContext.new(user_free, "dashboard")
      result = Cards::CardService.new(channel: channel, context: context).call

      headline = result[:layers][:headline][:data]
      expect(headline[:axes]).to be_present
      expect(headline[:state]).to eq("live")

      drill = result[:layers][:live_drill]
      expect(drill[:available]).to eq(true)
      expect(drill[:data]).to include(:erv_breakdown, :reason_codes_detail, :signal_breakdown)
    end
  end

  def auth_headers(user)
    token = Auth::JwtService.encode_access(user.id)
    { "Authorization" => "Bearer #{token}" }
  end

  describe "band tooltip locale coverage" do
    it "resolves every TOOLTIP_KEYS_BY_ROW key in RU and EN" do
      TrustIndex::V2::BandClassifier::TOOLTIP_KEYS_BY_ROW.each_value do |key|
        expect(I18n.t(key, locale: :ru, default: nil)).to be_present
        expect(I18n.t(key, locale: :en, default: nil)).to be_present
      end
    end
  end
end
