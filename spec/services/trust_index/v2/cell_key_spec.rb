# frozen_string_literal: true

require "rails_helper"

# One key, two callers: the engine resolves the cell to COMPUTE the soft bound, the card resolves
# it to SHOW what "below the norm" is measured against. A drift between them would put a baseline
# on screen that the verdict never used.
RSpec.describe TrustIndex::V2::CellKey do
  describe ".for" do
    it "normalises the Twitch game name into the category slug the corpus is keyed by" do
      stream = build(:stream, game_name: "Just Chatting", language: "RU")

      expect(described_class.for(stream: stream, v: 1_200)).to eq(
        category: "just_chatting", v_bucket: "1k-5k", chat_mode: "open", language: "RU"
      )
    end

    it "keeps the language verbatim — the corpus holds RU, not ru" do
      stream = build(:stream, language: "RU")

      expect(described_class.for(stream: stream, v: 10)[:language]).to eq("RU")
    end

    it "takes a category the caller already resolved instead of resolving it twice" do
      stream = build(:stream, game_name: "Just Chatting")

      expect(described_class.for(stream: stream, v: 10, category: "esports")[:category]).to eq("esports")
    end

    it "falls back to default on a stream with nothing to key on" do
      expect(described_class.for(stream: nil, v: nil)).to eq(
        category: "default", v_bucket: "0", chat_mode: "open", language: "default"
      )
    end
  end

  describe ".v_bucket" do
    it "maps the online onto the corpus buckets" do
      expect(described_class.v_bucket(0)).to eq("0")
      expect(described_class.v_bucket(999)).to eq("0-1k")
      expect(described_class.v_bucket(1_000)).to eq("1k-5k")
      expect(described_class.v_bucket(19_999)).to eq("5k-20k")
      expect(described_class.v_bucket(20_000)).to eq("20k+")
    end
  end

  describe ".chat_mode" do
    def config(**attrs) = ChannelProtectionConfig.new(**attrs)

    it "reports the restriction that most changes who can write" do
      expect(described_class.chat_mode(nil)).to eq("open")
      expect(described_class.chat_mode(config(subs_only_enabled: true, slow_mode_seconds: 30))).to eq("sub-only")
      expect(described_class.chat_mode(config(followers_only_duration_min: 0))).to eq("followers-only")
      expect(described_class.chat_mode(config(slow_mode_seconds: 30))).to eq("slow")
      expect(described_class.chat_mode(config(emote_only_enabled: true))).to eq("emote-only")
    end
  end
end
