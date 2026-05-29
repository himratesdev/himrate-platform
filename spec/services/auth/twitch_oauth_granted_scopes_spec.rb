# frozen_string_literal: true

require "rails_helper"

# BUG-TWITCH-SCOPE-ARRAY (2026-05-29) regression — Twitch's POST /oauth2/token returns
# `scope` field as a JSON Array, not a space-separated string. Original implementation
# (.to_s.split(" ")) mangled Array into "[\"a\",\"b\"]" then split on internal space →
# stored 3 corrupted strings with bracket fragments. Result: HelixFollowsSource
# `scope_granted?("user:read:follows")` returned false even though scope was granted,
# producing MissingFollowsScope failure. PO probe на staging 2026-05-29 confirmed.
RSpec.describe Auth::TwitchOauth, "#granted_scopes (private)" do
  let(:oauth) { described_class.new }

  def call_granted(tokens)
    oauth.send(:granted_scopes, tokens)
  end

  describe "Twitch's canonical Array response shape" do
    it "returns clean scope strings from Array" do
      tokens = { scope: %w[user:read:email channel:read:subscriptions user:read:follows] }
      expect(call_granted(tokens)).to eq(%w[user:read:email channel:read:subscriptions user:read:follows])
    end

    it "drops blanks from Array" do
      tokens = { scope: [ "user:read:email", "", "user:read:follows", nil ] }
      expect(call_granted(tokens)).to eq(%w[user:read:email user:read:follows])
    end

    it "stringifies non-string Array entries (defensive)" do
      tokens = { scope: [ :"user:read:email", "user:read:follows" ] }
      expect(call_granted(tokens)).to eq(%w[user:read:email user:read:follows])
    end
  end

  describe "Legacy space-separated String shape" do
    it "splits on spaces" do
      tokens = { scope: "user:read:email channel:read:subscriptions user:read:follows" }
      expect(call_granted(tokens)).to eq(%w[user:read:email channel:read:subscriptions user:read:follows])
    end

    it "falls back к SCOPES constant on empty string" do
      tokens = { scope: "" }
      expect(call_granted(tokens)).to eq(described_class::SCOPES.split(" "))
    end
  end

  describe "Missing / unexpected types" do
    it "falls back to SCOPES constant when scope is nil" do
      tokens = {}
      expect(call_granted(tokens)).to eq(described_class::SCOPES.split(" "))
    end

    it "falls back to SCOPES constant for unexpected scalar (Numeric)" do
      tokens = { scope: 12345 }
      expect(call_granted(tokens)).to eq(described_class::SCOPES.split(" "))
    end
  end
end
