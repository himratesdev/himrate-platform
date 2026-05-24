# frozen_string_literal: true

require "rails_helper"

RSpec.describe Auth::RedirectUriAllowlist do
  describe ".allowed?" do
    before do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:fetch).and_call_original
      allow(ENV).to receive(:[]).with("TWITCH_REDIRECT_URI")
        .and_return("https://staging.himrate.com/api/v1/auth/twitch/callback")
      allow(ENV).to receive(:[]).with("GOOGLE_REDIRECT_URI")
        .and_return("https://staging.himrate.com/api/v1/auth/google/callback")
      allow(ENV).to receive(:fetch).with("OAUTH_ALLOWED_REDIRECT_URIS", "")
        .and_return("https://gnnhhopjghkjdbjafhefmbckakbjkabp.chromiumapp.org/, https://other.chromiumapp.org/")
    end

    it "trusts the per-provider web-callback defaults" do
      expect(described_class).to be_allowed("https://staging.himrate.com/api/v1/auth/twitch/callback")
      expect(described_class).to be_allowed("https://staging.himrate.com/api/v1/auth/google/callback")
    end

    it "trusts URIs from OAUTH_ALLOWED_REDIRECT_URIS (comma-separated, trimmed)" do
      expect(described_class).to be_allowed("https://gnnhhopjghkjdbjafhefmbckakbjkabp.chromiumapp.org/")
      expect(described_class).to be_allowed("https://other.chromiumapp.org/")
    end

    it "rejects an untrusted redirect_uri" do
      expect(described_class).not_to be_allowed("https://evil.example.com/steal")
    end

    it "rejects blank or nil" do
      expect(described_class).not_to be_allowed("")
      expect(described_class).not_to be_allowed(nil)
    end
  end
end
