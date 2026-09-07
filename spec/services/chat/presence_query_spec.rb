# frozen_string_literal: true

require "rails_helper"

# Integration spec against the REAL ClickHouse in CI — the value of this class is its SQL, so a
# mocked client would test nothing. Logins are namespaced per example (shared append-only table).
RSpec.describe Chat::PresenceQuery do
  let(:a) { ns("alpha") }
  let(:b) { ns("beta") }
  let(:c) { ns("gamma") }
  let(:shared_users) { (1..6).map { |i| ns("u#{i}") } }

  describe "#audiences / #days_observed" do
    it "counts unique chatters and observed days per channel" do
      seed(a => shared_users + [ ns("solo") ])
      seed({ a => shared_users.first(2) }, date: Date.current - 1)

      q = described_class.new
      expect(q.audiences([ a ])[a]).to eq(7)
      expect(q.days_observed([ a ])[a]).to eq(2)
    end

    it "separates sources: :monitored sees only the archive population" do
      seed({ a => shared_users }, source: :farm)
      seed({ a => [ ns("mon_only") ] }, source: :monitored)

      expect(described_class.new(scope: :all).audiences([ a ])[a]).to eq(7)
      expect(described_class.new(scope: :monitored).audiences([ a ])[a]).to eq(1)
    end
  end

  describe "#edges" do
    it "returns shared counts for pairs at or above the floor, strongest first" do
      seed(a => shared_users + [ ns("only_a") ], b => shared_users, c => [ ns("loner") ])

      edges = described_class.new.edges([ a, b, c ])

      expect(edges.size).to eq(1)
      expect(edges.first).to include(shared: 6)
      expect([ edges.first[:a], edges.first[:b] ]).to contain_exactly(a, b)
    end

    it "drops pairs below MIN_SHARED" do
      thin = (1..3).map { |i| ns("t#{i}") }
      seed(a => thin, b => thin)

      expect(described_class.new.edges([ a, b ])).to be_empty
    end

    it "excludes serial lurkers present in more than MAX_USER_CHANNELS channels" do
      lurkers = (1..6).map { |i| ns("lurk#{i}") }
      seed(a => lurkers, b => lurkers)
      # each lurker also sits in 30 more channels → over the cap, so the pair loses its only tie
      31.times { |i| seed(ns("noise#{i}") => lurkers) }

      expect(described_class.new.edges([ a, b ])).to be_empty
    end
  end

  describe "#neighbours" do
    it "finds the ego channel's first circle, including untracked channels" do
      seed(a => shared_users, b => shared_users, c => shared_users.first(2))

      neighbours = described_class.new.neighbours(a)

      expect(neighbours.map { |n| n[:login] }).to include(b)
      expect(neighbours.find { |n| n[:login] == b }[:shared]).to eq(6)
      expect(neighbours.map { |n| n[:login] }).not_to include(c) # 2 shared < MIN_SHARED
    end
  end

  describe "#chatter_sets / #top_channels" do
    it "returns per-channel username sets and ranks channels by audience within a scope" do
      seed(a => shared_users + [ ns("extra") ], b => shared_users.first(3))

      q = described_class.new
      sets = q.chatter_sets([ a, b ])
      expect(sets[a].size).to eq(7)
      expect(sets[b].size).to eq(3)
      expect(q.top_channels(2, within: [ a, b ])).to eq([ a, b ])
    end
  end
end
