# frozen_string_literal: true

require "rails_helper"

RSpec.describe Coordination::GroupBuilder do
  # Two disjoint rings plus one loose pair, the shape live data actually produced on 2026-09-09.
  let(:pairs) do
    [
      { a: "alpha", b: "beta",  accounts_shared: 40, events: 400 },
      { a: "alpha", b: "gamma", accounts_shared: 30, events: 300 },
      { a: "beta",  b: "gamma", accounts_shared: 25, events: 250 },
      { a: "delta", b: "epsilon", accounts_shared: 12, events: 120 },
      { a: "delta", b: "zeta",    accounts_shared: 11, events: 110 },
      { a: "epsilon", b: "zeta",  accounts_shared: 10, events: 100 },
      { a: "lone1", b: "lone2", accounts_shared: 9, events: 90 }
    ]
  end

  let(:accounts) do
    [
      { username: "bot1", events: 10, max_concurrent: 3, channels: %w[alpha beta gamma], last_at: nil },
      { username: "bot2", events: 8,  max_concurrent: 3, channels: %w[alpha beta], last_at: nil },
      { username: "bot3", events: 6,  max_concurrent: 3, channels: %w[delta epsilon zeta], last_at: nil },
      # present in the ring but linking nothing — one channel is presence, not a tie
      { username: "human", events: 4, max_concurrent: 3, channels: %w[alpha unrelated], last_at: nil }
    ]
  end

  it "splits the edges into disjoint rings and drops a pair (a group must be able to host an event)" do
    groups = described_class.call(pairs:, accounts:)

    expect(groups.map(&:member_logins)).to contain_exactly(%w[alpha beta gamma], %w[delta epsilon zeta])
  end

  it "counts only accounts that tie at least two of the ring's channels" do
    ring = described_class.call(pairs:, accounts:).find { |g| g.member_logins.include?("alpha") }

    expect(ring.accounts.map { |a| a[:username] }).to contain_exactly("bot1", "bot2")
    expect(ring.accounts_shared).to eq(2)
    expect(ring.events).to eq(18)
    expect(ring.accounts.find { |a| a[:username] == "bot1" }[:channels_in_group]).to eq(3)
  end

  it "reports density as the share of member pairs carrying an edge" do
    groups = described_class.call(pairs:, accounts:)

    expect(groups.map(&:density).uniq).to eq([ 1.0 ]) # 3 edges over 3 possible pairs

    sparse = described_class.call(
      pairs: [ { a: "a", b: "b", accounts_shared: 9, events: 9 },
              { a: "b", b: "c", accounts_shared: 9, events: 9 } ],
      accounts: [ { username: "u", events: 3, max_concurrent: 3, channels: %w[a b c], last_at: nil } ]
    )
    expect(sparse.first.density).to eq(0.667) # 2 of 3
  end

  it "returns nothing when no account ties the ring" do
    expect(described_class.call(pairs:, accounts: [])).to be_empty
  end

  it "orders rings by the size of the shared pool" do
    big = (1..5).map { |i| { username: "b#{i}", events: 2, max_concurrent: 3, channels: %w[delta epsilon zeta], last_at: nil } }
    groups = described_class.call(pairs:, accounts: accounts + big)

    expect(groups.first.member_logins).to eq(%w[delta epsilon zeta])
  end
end
