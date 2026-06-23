# frozen_string_literal: true

require "rails_helper"

# T1-060 FR-5: JWT `aud` surface claim. Backward-compat is load-bearing — every existing
# encode_access(id) call-site must keep working (default extension) and legacy tokens
# minted before this change (no aud) must still decode.
RSpec.describe Auth::JwtService, type: :model do
  describe "surface (aud) claim" do
    it "defaults encode_access to the extension surface" do
      payload = described_class.decode(described_class.encode_access("u-1"))
      expect(payload[:aud]).to eq("extension")
    end

    it "defaults encode_refresh to the extension surface" do
      payload = described_class.decode(described_class.encode_refresh("u-1"))
      expect(payload[:aud]).to eq("extension")
      expect(payload[:type]).to eq("refresh")
    end

    it "stamps the dashboard surface when requested" do
      payload = described_class.decode(described_class.encode_access("u-1", surface: "dashboard"))
      expect(payload[:aud]).to eq("dashboard")
    end

    it "decodes a legacy token minted without aud (no verify_aud enforcement)" do
      legacy = JWT.encode(
        { sub: "u-1", type: "access", exp: 1.hour.from_now.to_i, iat: Time.current.to_i },
        described_class::SECRET, described_class::ALGORITHM
      )
      payload = described_class.decode(legacy)
      expect(payload[:aud]).to be_nil # → resolves to EXTENSION downstream (BR-8)
    end
  end
end
