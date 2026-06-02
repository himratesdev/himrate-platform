# frozen_string_literal: true

require "rails_helper"

RSpec.describe CrossChannelDigest do
  describe "schema + validations" do
    it "requires username, distinct_channels_24h, refreshed_at" do
      digest = described_class.new
      expect(digest).not_to be_valid
      expect(digest.errors[:username]).to be_present
      expect(digest.errors[:distinct_channels_24h]).to be_present
      expect(digest.errors[:refreshed_at]).to be_present
    end

    it "rejects negative distinct_channels_24h" do
      digest = described_class.new(username: "user", distinct_channels_24h: -1, refreshed_at: Time.current)
      expect(digest).not_to be_valid
      expect(digest.errors[:distinct_channels_24h]).to be_present
    end

    it "accepts zero distinct_channels_24h (single-channel chatters could be inserted by callers)" do
      digest = described_class.new(username: "user", distinct_channels_24h: 0, refreshed_at: Time.current)
      expect(digest).to be_valid
    end
  end

  describe ".bulk_lookup" do
    let(:t) { Time.current }

    before do
      described_class.upsert_all([
        { username: "alice", distinct_channels_24h: 4, refreshed_at: t },
        { username: "bob",   distinct_channels_24h: 2, refreshed_at: t },
        { username: "carol", distinct_channels_24h: 7, refreshed_at: t }
      ], unique_by: :username)
    end

    it "returns Hash<username, count> for matches" do
      result = described_class.bulk_lookup(%w[alice bob])
      expect(result).to eq("alice" => 4, "bob" => 2)
    end

    it "omits missing usernames (no zero-fill)" do
      result = described_class.bulk_lookup(%w[alice unknown_user])
      expect(result).to eq("alice" => 4)
    end

    it "returns {} for empty input" do
      expect(described_class.bulk_lookup([])).to eq({})
      expect(described_class.bulk_lookup(nil)).to eq({})
    end

    it "is case-insensitive (citext primary key)" do
      result = described_class.bulk_lookup(%w[ALICE Bob])
      expect(result.keys.map(&:downcase)).to match_array(%w[alice bob])
      expect(result.values.sort).to eq([ 2, 4 ])
    end
  end
end
