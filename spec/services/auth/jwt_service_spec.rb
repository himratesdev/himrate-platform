# frozen_string_literal: true

require "rails_helper"

RSpec.describe Auth::JwtService do
  let(:user_id) { SecureRandom.uuid }

  describe ".encode_access / .decode" do
    it "encodes and decodes access token" do
      token = described_class.encode_access(user_id)
      payload = described_class.decode(token)

      expect(payload[:sub]).to eq(user_id)
      expect(payload[:type]).to eq("access")
    end
  end

  describe ".encode_refresh / .decode" do
    it "encodes and decodes refresh token" do
      token = described_class.encode_refresh(user_id)
      payload = described_class.decode(token)

      expect(payload[:sub]).to eq(user_id)
      expect(payload[:type]).to eq("refresh")
    end
  end

  # T-011: JWT forgery
  describe "forged token" do
    it "raises AuthError for invalid token" do
      expect { described_class.decode("forged.token.here") }
        .to raise_error(Auth::JwtService::AuthError)
    end
  end
end
