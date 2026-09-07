# frozen_string_literal: true

require "rails_helper"

# Integration spec against the REAL ClickHouse in CI — the value here is the SQL (ClickHouse rejects
# correlated subqueries, which is exactly how the first version broke), so a mocked client would
# prove nothing. Handles are namespaced: social_posts is a shared append-only table.
RSpec.describe SocialAnalytics::PostOverlap do
  let(:client) { Clickhouse::Client.new }
  let(:tag) { SecureRandom.hex(4) }
  let(:solo) { "solo_#{tag}" }
  let(:a) { "chan_a_#{tag}" }
  let(:b) { "chan_b_#{tag}" }

  def insert(handle, text_hash:, giveaway: 0, views: 1000, minutes_ago: 60, post_id: nil)
    client.insert("social_posts", [ {
      platform: "telegram", handle: handle, post_id: post_id || SecureRandom.hex(4),
      published_at: minutes_ago.minutes.ago.utc.strftime("%Y-%m-%d %H:%M:%S"),
      views: views, text: "post #{text_hash}", text_hash: text_hash,
      links: [], has_giveaway: giveaway
    } ])
  end

  describe "#context_for" do
    it "reports a repost when the same text appears in another channel" do
      shared_hash = rand(1..2**60)
      insert(a, text_hash: shared_hash)
      insert(b, text_hash: shared_hash)

      context = described_class.new.context_for(a)

      expect(context[:reposted]).to be(true)
      expect(context[:posts_seen]).to eq(1)
    end

    it "does not call a channel's own unique post a repost" do
      insert(solo, text_hash: rand(1..2**60))

      context = described_class.new.context_for(solo)

      expect(context[:reposted]).to be(false)
      expect(context[:giveaway]).to be(false)
    end

    it "reports a giveaway post" do
      insert(solo, text_hash: rand(1..2**60), giveaway: 1)

      expect(described_class.new.context_for(solo)[:giveaway]).to be(true)
    end
  end

  describe "#clusters" do
    it "groups the same post across channels into one repost cluster" do
      shared_hash = rand(1..2**60)
      insert(a, text_hash: shared_hash, views: 5_000)
      insert(b, text_hash: shared_hash, views: 3_000)

      cluster = described_class.new.clusters(limit: 200).find { |c| c[:text_hash].to_i == shared_hash }

      expect(cluster[:channels]).to contain_exactly(a, b)
      expect(cluster[:posts]).to eq(2)
      expect(cluster[:total_views]).to eq(8_000)
    end
  end
end
