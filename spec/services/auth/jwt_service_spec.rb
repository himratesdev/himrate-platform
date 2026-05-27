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
        .to raise_error(Auth::AuthError)
    end
  end

  # BUG-251.16: empty-key HMAC bypass (CVE-2026-45363).
  describe "empty-key HMAC bypass (CVE-2026-45363)" do
    it "boots with a non-blank signing secret" do
      expect(described_class::SECRET).to be_present
    end

    it "refuses empty-key HMAC operations at the gem level (jwt >= 2.10.3 patch)" do
      expect { JWT.encode({ sub: user_id }, "", "HS256") }
        .to raise_error(JWT::DecodeError, /HMAC key cannot be empty/)
    end
  end
end
