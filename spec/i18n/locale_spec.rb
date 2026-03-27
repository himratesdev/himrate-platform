# frozen_string_literal: true

require "rails_helper"

RSpec.describe "i18n Configuration" do
  # TC-001: Accept-Language: ru → RU response
  # TC-002: Accept-Language: en → EN response
  describe "locale detection via API" do
    let(:user) { create(:user) }
    let(:token) { Auth::JwtService.encode_access(user.id) }
    let(:channel) { create(:channel) }

    it "returns RU error for Accept-Language: ru", type: :request do
      Flipper.enable(:pundit_authorization)
      get "/api/v1/channels/#{channel.id}/streams",
          headers: { "Authorization" => "Bearer #{token}", "Accept-Language" => "ru" }
      body = JSON.parse(response.body)
      expect(body.dig("error", "message")).to include("аналитика")
    end

    it "returns EN error for Accept-Language: en", type: :request do
      Flipper.enable(:pundit_authorization)
      get "/api/v1/channels/#{channel.id}/streams",
          headers: { "Authorization" => "Bearer #{token}", "Accept-Language" => "en" }
      body = JSON.parse(response.body)
      expect(body.dig("error", "message")).to include("analytics")
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

  # TC-004: Accept-Language: zh → EN fallback
  describe "fallback for unsupported locale" do
    it "falls back to EN for unsupported language" do
      controller = Api::BaseController.new
      allow(controller).to receive(:request).and_return(
        double(headers: { "Accept-Language" => "zh-CN" })
      )
      expect(controller.send(:extract_locale_from_header)).to eq(:en)
    end
  end

  # TC-005: Missing key in ru → EN fallback
  describe "missing key fallback" do
    it "falls back to EN when key missing in RU" do
      I18n.with_locale(:ru) do
        result = I18n.t("hello")
        expect(result).to eq("Hello world")
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
