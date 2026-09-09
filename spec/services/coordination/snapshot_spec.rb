# frozen_string_literal: true

require "rails_helper"

RSpec.describe Coordination::Snapshot do
  let(:a) { ns("ring_a") }
  let(:b) { ns("ring_b") }
  let(:c) { ns("ring_c") }
  let(:hour) { 2.hours.ago.utc.beginning_of_hour }
  let(:pool) { (1..8).map { |i| ns("pool#{i}") } }

  def seed_ring(channels: [ a, b, c ])
    pool.each { |u| seed_coordination(hour, u => { channels: channels, events: 4, max_concurrent: 3 }) }
  end

  it "persists the ring with its members, edges and account evidence" do
    seed_ring
    create(:channel, login: a, display_name: "Ring A")

    stats = described_class.call(window_days: 1)

    expect(stats[:groups]).to be >= 1
    group = CoordinationGroup.for_channel_login(a).first
    expect(group.member_count).to eq(3)
    expect(group.accounts_shared).to eq(8)
    expect(group.density).to eq(1.0)
    expect(group.window_days).to eq(1)
    expect(group.members.pluck(:channel_login)).to match_array([ a, b, c ])
    expect(group.edges.count).to eq(3)
    expect(group.accounts.pluck(:username)).to match_array(pool)
    # tracked channel gets its Channel row linked; the other two stay login-only
    expect(group.members.find_by(channel_login: a).channel_id).to be_present
    expect(group.members.find_by(channel_login: b).channel_id).to be_nil
  end

  it "stays an observation until the engine's own named-bot evidence corroborates it" do
    seed_ring
    described_class.call(window_days: 1)
    expect(CoordinationGroup.for_channel_login(a).first.corroborated).to be(false)

    # Five flagged accounts across two of the ring's channels — the licensing threshold.
    ch_a = create(:channel, login: a)
    ch_b = create(:channel, login: b)
    pool.first(3).each { |u| create(:named_bot_evidence, channel: ch_a, username: u) }
    pool.last(2).each  { |u| create(:named_bot_evidence, channel: ch_b, username: u) }

    described_class.call(window_days: 1)

    group = CoordinationGroup.for_channel_login(a).first
    expect(group.corroborated).to be(true)
    expect(group.corroborated_accounts).to eq(5)
    expect(group.corroborated_channels).to eq(2)
    expect(group.accounts.where(named_bot: true).count).to eq(5)
  end

  it "refuses to corroborate when the flagged accounts sit in a single channel" do
    seed_ring
    ch_a = create(:channel, login: a)
    pool.first(6).each { |u| create(:named_bot_evidence, channel: ch_a, username: u) }

    described_class.call(window_days: 1)

    group = CoordinationGroup.for_channel_login(a).first
    expect(group.corroborated).to be(false)
    expect(group.corroborated_channels).to eq(1)
  end

  it "keeps a ring's id and first-seen across a recompute that shifts one member" do
    seed_ring
    described_class.call(window_days: 1)
    original = CoordinationGroup.for_channel_login(a).first
    original.update_column(:first_seen_at, 5.days.ago)

    d = ns("ring_d")
    pool.each { |u| seed_coordination(hour - 1.hour, u => { channels: [ a, b, d ], events: 4, max_concurrent: 3 }) }
    described_class.call(window_days: 1)

    reloaded = CoordinationGroup.for_channel_login(a).first
    expect(reloaded.id).to eq(original.id)
    expect(reloaded.first_seen_at).to be < 4.days.ago
    expect(reloaded.members.pluck(:channel_login)).to include(d)
  end

  it "drops a ring that no longer exists in the window" do
    seed_ring
    described_class.call(window_days: 1)
    expect(CoordinationGroup.for_channel_login(a)).to be_present

    # A window in which the seeded hour is out of range leaves nothing to assemble.
    allow(Clickhouse::CoordinationQueries).to receive(:accounts).and_return([])
    allow(Clickhouse::CoordinationQueries).to receive(:channel_pairs).and_return([])
    described_class.call(window_days: 1)

    expect(CoordinationGroup.count).to eq(0)
    expect(CoordinationGroupMember.count).to eq(0)
    expect(CoordinationAccount.count).to eq(0)
  end

  it "survives a ClickHouse failure while measuring rhythm — the finding is not the colour" do
    seed_ring
    allow(Clickhouse::CoordinationQueries).to receive(:rhythm).and_raise(Clickhouse::QueryError, "boom")

    expect { described_class.call(window_days: 1) }.not_to raise_error
    expect(CoordinationGroup.for_channel_login(a).first.accounts.count).to eq(8)
  end
end
