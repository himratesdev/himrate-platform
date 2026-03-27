# frozen_string_literal: true

require "rails_helper"

RSpec.describe "CORS", type: :request do
  let(:extension_id) { "gnnhhopjghkjdbjafhefmbckakbjkabp" }
  let(:valid_origin) { "chrome-extension://#{extension_id}" }
  let(:invalid_origin) { "chrome-extension://invalidextensionidhere" }

  around do |example|
    ClimateControl.modify(ALLOWED_EXTENSION_ID: extension_id) do
      example.run
    end
  end

  describe "GET /api/v1/channels with valid Origin" do
    it "includes CORS headers" do
      get "/api/v1/channels", headers: { "Origin" => valid_origin }

      expect(response.headers["Access-Control-Allow-Origin"]).to eq(valid_origin)
      expect(response.headers["Access-Control-Allow-Credentials"]).to eq("true")
    end
  end

  describe "GET /api/v1/channels with invalid Origin" do
    it "does not include CORS headers" do
      get "/api/v1/channels", headers: { "Origin" => invalid_origin }

      expect(response.headers["Access-Control-Allow-Origin"]).to be_nil
    end
  end

  describe "OPTIONS /api/v1/channels preflight" do
    it "returns correct CORS headers" do
      options "/api/v1/channels", headers: {
        "Origin" => valid_origin,
        "Access-Control-Request-Method" => "GET",
        "Access-Control-Request-Headers" => "Authorization"
      }

      expect(response.headers["Access-Control-Allow-Origin"]).to eq(valid_origin)
      expect(response.headers["Access-Control-Allow-Methods"]).to include("GET")
      expect(response.headers["Access-Control-Max-Age"]).to eq("86400")
    end
  end

  describe "GET /health (non-API route)" do
    it "does not include CORS headers" do
      get "/health", headers: { "Origin" => valid_origin }

      expect(response.headers["Access-Control-Allow-Origin"]).to be_nil
    end
  end
end
