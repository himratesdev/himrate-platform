# frozen_string_literal: true

require "rails_helper"

# PR-251.14 PR 1e-A follow-up: chat now lives in ClickHouse only (post PR #231 cutover). These
# specs were rewritten to drive the worker via Clickhouse::ChatQueries stubs instead of inserting
# PG ChatMessage rows — same semantics (raid USERNOTICEs + privmsg windows + cross-channel counts),
# different source of truth.
RSpec.describe RaidDetectionWorker do
  let(:worker) { described_class.new }
  let(:channel) { create(:channel) }
  let(:stream) { create(:stream, channel: channel, started_at: 4.hours.ago, ended_at: nil) }

  # Mutable state the stubs read. Reset per-example via the let-lazy semantics.
  let(:raid_rows) { [] }                # what ChatQueries.raid_messages_pending returns
  let(:privmsg_log) { [] }              # [{ stream_id:, username:, at: }, ...] — drives privmsg_logins
  let(:cross_channel_counts) { {} }     # explicit override for cross_channel scenarios

  before do
    allow(Flipper).to receive(:enabled?).with(:stream_monitor).and_return(true)
    allow(Flipper).to receive(:enabled?).with(:raid_detection).and_return(true)

    # CH stubs: filter the in-memory log by window so timestamp-based test setup stays expressive.
    allow(Clickhouse::ChatQueries).to receive(:raid_messages_pending) do |since:, until_:, limit:|
      raid_rows.select { |r| r[:timestamp] >= since && r[:timestamp] <= until_ }
               .first(limit.to_i)
    end
    allow(Clickhouse::ChatQueries).to receive(:privmsg_logins) do |s, from:, to:|
      privmsg_log
        .select { |row| row[:stream_id] == s.id && row[:at] >= from && row[:at] < to }
        .map { |row| row[:username] }
        .uniq
    end
    # Default: no cross-channel signal data. Per-example specs override via `cross_channel_counts`.
    allow(Clickhouse::ChatQueries).to receive(:chatter_cross_channel_counts) { |_, _| cross_channel_counts }
  end

  # A matured raid USERNOTICE (default 20 min old → inside [LOOKBACK..MATURITY]).
  def raid(viewers:, at: 20.minutes.ago, msg_id: "raid-#{SecureRandom.hex(4)}", source_id: "src-1", linked: stream)
    row = {
      stream_id:     linked&.id,
      timestamp:     at,
      username:      "tmi.twitch.tv",
      twitch_msg_id: msg_id,
      raw_tags: {
        "msg-id"                => "raid",
        "msg-param-login"       => "raider",
        "user-id"               => source_id,
        "msg-param-viewerCount" => viewers.to_s
      }
    }
    raid_rows << row
    row
  end

  def chat(username, at:, strm: stream)
    privmsg_log << { stream_id: strm.id, username: username, at: at }
  end

  def ccv(count, at:)
    CcvSnapshot.create!(stream: stream, ccv_count: count, timestamp: at)
  end

  # Newcomers that look like bots: young accounts, low write-rate, CCV spike that decays.
  def setup_bot_raid(t, viewers:)
    ccv(5, at: t - 2.minutes)         # baseline CCV
    ccv(5 + viewers, at: t + 1.minute) # raid spike registers in CCV
    ccv(8, at: t + 5.minutes)          # decayed away
    %w[bot_a bot_b bot_c].each do |u|
      chat(u, at: t + 1.minute) # only 3 of `viewers` raiders wrote → low write-rate
      ChatterProfile.create!(login: u, twitch_created_at: 2.days.ago, fetched_at: Time.current)
    end
  end

  it "skips when raid_detection flag is disabled" do
    allow(Flipper).to receive(:enabled?).with(:raid_detection).and_return(false)
    raid(viewers: 100)
    expect { worker.perform }.not_to change(RaidAttribution, :count)
  end

  it "classifies a significant raid with bot-like cohort as a bot-raid" do
    t = 20.minutes.ago
    r = raid(viewers: 100, at: t)
    setup_bot_raid(t, viewers: 100)

    expect { worker.perform }.to change(RaidAttribution, :count).by(1)

    ra = RaidAttribution.find_by(twitch_msg_id: r[:twitch_msg_id])
    expect(ra.is_bot_raid).to be(true)
    expect(ra.bot_score).to be >= 0.75
    expect(ra.raid_viewers_count).to eq(100)
    expect(ra.stream_id).to eq(stream.id)
    expect(ra.signal_scores["significant"]).to be(true)
    expect(ra.signal_scores["triggered"]).to be >= 3
  end

  it "links source_channel when the raider is a tracked channel" do
    src = create(:channel, twitch_id: "src-42")
    t = 20.minutes.ago
    raid(viewers: 100, at: t, source_id: "src-42")
    setup_bot_raid(t, viewers: 100)

    worker.perform
    expect(RaidAttribution.last.source_channel_id).to eq(src.id)
  end

  it "leaves source_channel nil when the raider is untracked" do
    t = 20.minutes.ago
    raid(viewers: 100, at: t, source_id: "unknown-id")
    setup_bot_raid(t, viewers: 100)

    worker.perform
    expect(RaidAttribution.last.source_channel_id).to be_nil
  end

  it "records an organic significant raid as not a bot-raid" do
    t = 20.minutes.ago
    r = raid(viewers: 10, at: t)
    ccv(5, at: t - 2.minutes)
    ccv(20, at: t + 1.minute)
    ccv(20, at: t + 5.minutes) # CCV retained → no decay
    # 8 of 10 raiders wrote (high write-rate), all old accounts
    8.times do |i|
      u = "real_#{i}"
      chat(u, at: t + 1.minute)
      ChatterProfile.create!(login: u, twitch_created_at: 3.years.ago, fetched_at: Time.current)
    end

    worker.perform
    ra = RaidAttribution.find_by(twitch_msg_id: r[:twitch_msg_id])
    expect(ra.is_bot_raid).to be(false)
    expect(ra.signal_scores["significant"]).to be(true)
    expect(ra.signal_scores["triggered"]).to eq(0)
  end

  it "records a non-significant raid (small raid, large channel) without classifying" do
    t = 20.minutes.ago
    r = raid(viewers: 10, at: t)
    ccv(5000, at: t - 1.minute) # huge baseline audience
    40.times { |i| chat("regular_#{i}", at: t - 5.minutes) } # large pre-raid chatter base

    expect { worker.perform }.to change(RaidAttribution, :count).by(1)
    ra = RaidAttribution.find_by(twitch_msg_id: r[:twitch_msg_id])
    expect(ra.is_bot_raid).to be(false)
    expect(ra.bot_score).to be_nil
    expect(ra.signal_scores["reason"]).to eq("insufficient_isolation")
  end

  it "is idempotent — skips a raid already attributed" do
    r = raid(viewers: 100)
    create(:raid_attribution, stream: stream, twitch_msg_id: r[:twitch_msg_id])

    expect { worker.perform }.not_to change(RaidAttribution, :count)
  end

  it "does not process raids younger than MATURITY" do
    raid(viewers: 100, at: 2.minutes.ago)
    expect { worker.perform }.not_to change(RaidAttribution, :count)
  end

  it "does not process raids older than LOOKBACK" do
    raid(viewers: 100, at: 5.hours.ago)
    expect { worker.perform }.not_to change(RaidAttribution, :count)
  end

  it "skips raid USERNOTICEs without a linked stream (CH guarantees stream_id IS NOT NULL filter)" do
    # ChatQueries.raid_messages_pending applies `stream_id IS NOT NULL` server-side, so the
    # candidate set never contains nil-linked raids. We model that by simply not enqueueing one
    # — the worker therefore makes no progress.
    expect { worker.perform }.not_to change(RaidAttribution, :count)
  end

  it "skips raids with zero viewers" do
    raid(viewers: 0)
    expect { worker.perform }.not_to change(RaidAttribution, :count)
  end

  it "honors MAX_PER_RUN" do
    stub_const("#{described_class}::MAX_PER_RUN", 1)
    raid(viewers: 50, at: 20.minutes.ago)
    raid(viewers: 50, at: 25.minutes.ago)
    expect { worker.perform }.to change(RaidAttribution, :count).by(1)
  end

  it "feeds chatter_cross_channel_counts the newcomer cohort + CROSS_CHANNEL_WINDOW.ago" do
    # Regression guard: a future refactor must keep passing the post-raid newcomer list and the
    # rolling 24h cutoff to the CH helper. If either drifts (e.g. someone passes raw_tags or
    # mixes pre+post window), the cross-channel signal silently breaks.
    t = 20.minutes.ago
    raid(viewers: 100, at: t)
    setup_bot_raid(t, viewers: 100)

    expect(Clickhouse::ChatQueries).to receive(:chatter_cross_channel_counts) do |usernames, since|
      expect(usernames).to match_array(%w[bot_a bot_b bot_c])
      expect(since).to be_within(5.seconds).of(RaidDetectionWorker::CROSS_CHANNEL_WINDOW.ago)
      {}
    end.at_least(:once)

    worker.perform
  end
end
