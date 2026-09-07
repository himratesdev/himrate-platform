# frozen_string_literal: true

require "rails_helper"

# Reads the ClickHouse presence layer (monitored archive + farm capture) with a Postgres-ledger
# fallback; CI runs a real ClickHouse, so the primary path is exercised for real.
RSpec.describe Brand::AudienceOverlapService, type: :service do
  # A = {alice, bob, eve}, B = {alice, carol}, C = {carol, dave}
  # overlaps: A∩B={alice}, A∩C={}, B∩C={carol}
  let(:login_a) { ns("aaa") }
  let(:login_b) { ns("bbb") }
  let(:login_c) { ns("ccc") }
  let(:alice) { ns("alice") }
  let(:carol) { ns("carol") }
  let!(:a) { create(:channel, login: login_a) }
  let!(:b) { create(:channel, login: login_b) }
  let!(:c) { create(:channel, login: login_c) }

  before do
    seed({login_a => [ alice, ns("bob"), ns("eve") ],
         login_b => [ alice, carol ],
         login_c => [ carol, ns("dave") ] })
  end

  it "rejects fewer than 2 channels" do
    expect(described_class.new([ login_a ]).call.error).to eq("CHANNELS_REQUIRED")
  end

  it "rejects an unknown login" do
    expect(described_class.new([ login_a, "ghost_#{SecureRandom.hex(3)}" ]).call.error).to eq("CHANNEL_NOT_FOUND")
  end

  it "falls back to the Postgres ledger when ClickHouse is unavailable" do
    allow_any_instance_of(Chat::PresenceQuery).to receive(:chatter_sets).and_raise(Clickhouse::QueryError, "down")
    create(:cross_channel_presence, channel: a, username: alice)
    create(:cross_channel_presence, channel: b, username: alice)

    payload = described_class.new([ login_a, login_b ]).call.payload
    expect(payload[:basis_source]).to eq("pg_ledger")
    expect(payload[:unique_reach]).to eq(1)
  end

  describe "overlap math for 3 channels" do
    subject(:payload) { described_class.new([ login_a, login_b, login_c ]).call.payload }

    it "computes unique and total reach" do
      expect(payload[:unique_reach]).to eq(5)   # alice bob eve carol dave
      expect(payload[:total_reach]).to eq(7)    # 3 + 2 + 2
    end

    it "computes pairwise overlap with strength" do
      # Match a pair regardless of (a, b) orientation so the assertion never depends on column order.
      pair = ->(x, y) { payload[:pairwise].find { |p| [ p[:a], p[:b] ].sort == [ x, y ].sort } }
      ab = pair.call(login_a, login_b)
      ac = pair.call(login_a, login_c)
      expect(ab[:shared]).to eq(1)               # alice
      expect(ab[:percent]).to eq(50.0)           # 1 / min(3,2)
      expect(ab[:strength]).to eq("strong")
      expect(ac[:shared]).to eq(0)
      expect(ac[:strength]).to eq("weak")
    end

    it "returns channels and pairwise in the REQUESTED order (deterministic, not DB order)" do
      expect(payload[:channels].map { |c| c[:login] }).to eq([ login_a, login_b, login_c ])
      # combination order over the requested channels → aaa×bbb, aaa×ccc, bbb×ccc
      expect(payload[:pairwise].map { |p| [ p[:a], p[:b] ] })
        .to eq([ [ login_a, login_b ], [ login_a, login_c ], [ login_b, login_c ] ])
    end

    it "composition sums to unique reach" do
      total = payload[:composition].sum { |seg| seg[:count] }
      expect(total).to eq(payload[:unique_reach])
      shared = payload[:composition].find { |s| s[:segment] == "shared_2plus" }
      expect(shared[:count]).to eq(2)            # alice, carol
    end

    it "labels the chatters-only basis, its source and window" do
      expect(payload[:audience_basis]).to eq("chat_presence")
      expect(payload[:basis_source]).to eq("clickhouse_presence")
      expect(payload[:window_days]).to eq(described_class::WINDOW_DAYS)
      expect(payload[:channels].first[:days_observed]).to eq(1)
    end
  end
end
