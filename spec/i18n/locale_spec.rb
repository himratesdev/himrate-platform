# frozen_string_literal: true

require "rails_helper"

RSpec.describe "i18n Configuration" do
  # TC-001: Accept-Language: ru → RU response
  # TC-002: Accept-Language: en → EN response
  describe "locale detection via API" do
    let(:user) { create(:user) }
    let(:token) { Auth::JwtService.encode_access(user.id) }
    let(:channel) { create(:channel) }

    # T1-060: on the extension surface a free viewer's streams-history denial is the
    # honest-empty EXTENSION_DEEP_LOCKED message; assert its locale-distinguishing words.
    it "returns RU error for Accept-Language: ru", type: :request do
      Flipper.enable(:pundit_authorization)
      get "/api/v1/channels/#{channel.id}/streams",
          headers: { "Authorization" => "Bearer #{token}", "Accept-Language" => "ru" }
      body = JSON.parse(response.body)
      expect(body.dig("error", "message")).to include("кабинете")
    end

    it "returns EN error for Accept-Language: en", type: :request do
      Flipper.enable(:pundit_authorization)
      get "/api/v1/channels/#{channel.id}/streams",
          headers: { "Authorization" => "Bearer #{token}", "Accept-Language" => "en" }
      body = JSON.parse(response.body)
      expect(body.dig("error", "message")).to include("dashboard")
    end
  end

  # TC-003: No header → EN default
  describe "default locale" do
    it "default_locale is :en" do
      expect(I18n.default_locale).to eq(:en)
    end

    it "available_locales includes en and ru" do
      expect(I18n.available_locales).to include(:en, :ru)
    end
  end

  # TC-004: Accept-Language: zh → EN fallback (via the shared LocaleResolver,
  # CR A3 — same logic used by Api::BaseController and MaintenanceMode).
  describe "fallback for unsupported locale" do
    it "falls back to EN for unsupported language" do
      env = Rack::MockRequest.env_for("/api/v1/channels/1", "HTTP_ACCEPT_LANGUAGE" => "zh-CN")
      expect(LocaleResolver.call(env)).to eq(:en)
    end

    it "?lang= query param wins over Accept-Language" do
      env = Rack::MockRequest.env_for("/api/v1/channels/1?lang=ru", "HTTP_ACCEPT_LANGUAGE" => "en-US,en;q=0.9")
      expect(LocaleResolver.call(env)).to eq(:ru)
    end

    it "no signal → I18n.default_locale" do
      env = Rack::MockRequest.env_for("/api/v1/channels/1")
      expect(LocaleResolver.call(env)).to eq(I18n.default_locale)
    end

    # CR N2: Accept-Language q-value preference (RFC 9110 §12.5.4). The first
    # entry may be an unsupported locale — pick the highest-q SUPPORTED one.
    it "honors q-values: 'fr-CA,ru;q=0.9' → :ru (skips unsupported :fr)" do
      env = Rack::MockRequest.env_for("/api/v1/channels/1", "HTTP_ACCEPT_LANGUAGE" => "fr-CA,ru;q=0.9")
      expect(LocaleResolver.call(env)).to eq(:ru)
    end

    it "prefers the higher q-value among supported locales ('en;q=0.3,ru;q=0.8' → :ru)" do
      env = Rack::MockRequest.env_for("/api/v1/channels/1", "HTTP_ACCEPT_LANGUAGE" => "en;q=0.3,ru;q=0.8")
      expect(LocaleResolver.call(env)).to eq(:ru)
    end

    it "ties keep header order ('en,ru' → :en)" do
      env = Rack::MockRequest.env_for("/api/v1/channels/1", "HTTP_ACCEPT_LANGUAGE" => "en,ru")
      expect(LocaleResolver.call(env)).to eq(:en)
    end

    it "falls back to default when no entry is supported ('fr,de;q=0.9' → :en)" do
      env = Rack::MockRequest.env_for("/api/v1/channels/1", "HTTP_ACCEPT_LANGUAGE" => "fr,de;q=0.9")
      expect(LocaleResolver.call(env)).to eq(I18n.default_locale)
    end
  end

  # TC-005: Missing key in ru → EN fallback
  describe "missing key fallback" do
    it "falls back to EN when key missing in RU" do
      I18n.with_locale(:ru) do
        result = I18n.t("auth.errors.bearer_required")
        expect(result).to eq("Bearer token required").or eq("Требуется Bearer токен")
      end
    end
  end

  # TC-006: auth_controller 0 hardcoded user-facing strings
  describe "no hardcoded strings" do
    it "auth_controller uses I18n.t for all user-facing messages" do
      source = File.read(Rails.root.join("app/controllers/api/v1/auth_controller.rb"))
      hardcoded_messages = source.scan(/message: "(?!.*I18n)([^"]+)"/)
      # Only OAuth provider error (dynamic from params) should be hardcoded
      hardcoded_messages.reject! { |m| m[0] == "error" }
      expect(hardcoded_messages).to be_empty
    end
  end

  # TC-007: base_controller 0 inline locale parsing
  describe "no inline locale parsing" do
    it "base_controller does not use inline Accept-Language parsing with locale: param" do
      source = File.read(Rails.root.join("app/controllers/api/base_controller.rb"))
      expect(source).not_to include('locale: locale')
      expect(source).not_to include('start_with?("ru")')
    end
  end
end
