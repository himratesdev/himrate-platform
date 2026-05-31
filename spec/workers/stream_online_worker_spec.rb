# frozen_string_literal: true

require "rails_helper"

RSpec.describe StreamOnlineWorker do
  # BUG-251.40-E (2026-06-01): regression guard — worker MUST enqueue to :stream_lifecycle
  # so new lifecycle events bypass the :signals historical backlog. String value
  # asserted explicitly (sidekiq_options stores verbatim; CR-229 iter-2 standardised on String).
  it "is enqueued on the :stream_lifecycle dedicated queue (string value per CR-229 iter-2 convention)" do
    expect(described_class.sidekiq_options["queue"]).to eq("stream_lifecycle")
  end

  it "uses retry: 3 (matches :bot_scoring / :signal_compute precedent; close_stale_if_fused + merge_or_create_stream idempotent)" do
    expect(described_class.sidekiq_options["retry"]).to eq(3)
  end

  let(:worker) { described_class.new }
  let(:channel) { create(:channel, twitch_id: "12345", login: "teststreamer") }

  before do
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:fetch).with("REDIS_URL", anything).and_return("redis://localhost:6379/1")

    stub_request(:post, "https://gql.twitch.tv/gql")
      .to_return(status: 200, body: { data: { user: { stream: nil, broadcastSettings: { title: "Test", language: "en", game: { name: "Just Chatting", id: "509658" } } } } }.to_json,
                 headers: { "Content-Type" => "application/json" })

    # Clear Redis pub/sub (no-op needed)
  end

  let(:event_data) do
    {
      "broadcaster_user_id" => channel.twitch_id,
      "broadcaster_user_login" => channel.login,
      "started_at" => Time.current.iso8601,
      "type" => "live",
      # BUG-251.40 A2: Helix per-broadcast id forwarded via `stream_id` key
      # (MonitoredLiveDetectorWorker convention). EventSub equivalent uses `id` — covered separately.
      "stream_id" => "316159655126"
    }
  end

  # TC-001: Creates Stream record
  it "creates a Stream record on stream.online" do
    expect { worker.perform(event_data) }.to change(Stream, :count).by(1)

    stream = channel.streams.order(created_at: :desc).first
    expect(stream.channel).to eq(channel)
    expect(stream.started_at).to be_present
    expect(stream.ended_at).to be_nil
    expect(stream.twitch_stream_id).to eq("316159655126")
  end

  # TC-002: Auto-creates Channel
  it "auto-creates Channel if not found" do
    event = event_data.merge("broadcaster_user_id" => "99999", "broadcaster_user_login" => "newstreamer")

    expect { worker.perform(event) }.to change(Channel, :count).by(1)
    expect(Channel.find_by(twitch_id: "99999").login).to eq("newstreamer")
  end

  # TC-003: continuation — active stream with MATCHING twitch_stream_id → skip create (idempotency).
  # BUG-251.40 A2: idempotency keyed on (channel, twitch_stream_id) instead of channel-only.
  it "skips creating new Stream when active stream with matching twitch_stream_id exists" do
    create(:stream, channel: channel, ended_at: nil, twitch_stream_id: "316159655126")

    expect { worker.perform(event_data) }.not_to change(Stream, :count)
  end

  # BUG-251.29: previously returned early without publishing IRC join → IRC stayed out of sync
  # when the existing row was stale (Twitch session ended without offline reaching us) OR
  # IrcMonitor was restarted mid-session and dropped its in-memory set.
  it "still publishes IRC join idempotently when active stream exists (BUG-251.29)" do
    create(:stream, channel: channel, ended_at: nil, twitch_stream_id: "316159655126")

    redis_spy = instance_double(Redis)
    allow(Redis).to receive(:new).and_return(redis_spy)
    expect(redis_spy).to receive(:publish).with(
      "irc:commands",
      { action: "join", channel_login: channel.login }.to_json
    )

    worker.perform(event_data)
  end

  # TC-004: Stream merge
  it "merges with previous stream if <30min gap and same category" do
    old_stream = create(:stream, channel: channel, ended_at: 10.minutes.ago, game_name: "Just Chatting")
    event = event_data.merge("category_name" => "Just Chatting")

    expect { worker.perform(event) }.not_to change(Stream, :count)

    old_stream.reload
    expect(old_stream.ended_at).to be_nil
    expect(old_stream.merge_status).to eq("merged")
  end

  # TC-005: No merge (different category)
  it "creates new stream if category changed" do
    create(:stream, channel: channel, ended_at: 10.minutes.ago, game_name: "Fortnite")
    event = event_data.merge("category_name" => "Just Chatting")

    expect { worker.perform(event) }.to change(Stream, :count).by(1)
  end

  # TASK-033 TC-004: Merge increments merged_parts_count and records part_boundaries
  it "increments merged_parts_count and records part_boundaries on merge" do
    old_stream = create(:stream, channel: channel, started_at: 2.hours.ago, ended_at: 10.minutes.ago,
      game_name: "Just Chatting", merged_parts_count: 1, part_boundaries: [])

    create(:trust_index_history,
      channel: channel, stream: old_stream,
      trust_index_score: 65.0, erv_percent: 65.0, ccv: 3000,
      confidence: 0.8, classification: "needs_review", cold_start_status: "full",
      signal_breakdown: {}, calculated_at: 11.minutes.ago)

    worker.perform(event_data)

    old_stream.reload
    expect(old_stream.merged_parts_count).to eq(2)
    expect(old_stream.part_boundaries.size).to eq(1)
    expect(old_stream.part_boundaries.first["ti_score"]).to eq(65.0)
  end

  # TASK-033 TC-005: =30min → NOT merge
  it "does NOT merge when gap is exactly 30 minutes" do
    create(:stream, channel: channel, started_at: 2.hours.ago, ended_at: 30.minutes.ago,
      game_name: "Just Chatting")

    expect { worker.perform(event_data) }.to change(Stream, :count).by(1)
  end

  # TASK-033 TC-007: 3 reconnects → parts_count=3, 2 boundaries
  it "handles multiple reconnects with cumulative part_boundaries" do
    old_stream = create(:stream, channel: channel, started_at: 3.hours.ago, ended_at: 10.minutes.ago,
      game_name: "Just Chatting", merged_parts_count: 2,
      part_boundaries: [ { "ended_at" => 1.hour.ago.iso8601, "ti_score" => 60.0, "erv_percent" => 60.0, "part_number" => 1 } ])

    create(:trust_index_history,
      channel: channel, stream: old_stream,
      trust_index_score: 70.0, erv_percent: 70.0, ccv: 4000,
      confidence: 0.85, classification: "needs_review", cold_start_status: "full",
      signal_breakdown: {}, calculated_at: 11.minutes.ago)

    worker.perform(event_data)

    old_stream.reload
    expect(old_stream.merged_parts_count).to eq(3)
    expect(old_stream.part_boundaries.size).to eq(2)
  end

  # TASK-033: nil game_name fallback — both nil → merge
  it "merges when both game_names are nil (GQL failure)" do
    old_stream = create(:stream, channel: channel, ended_at: 10.minutes.ago, game_name: nil)

    # Stub GQL to return nil game
    stub_request(:post, "https://gql.twitch.tv/gql")
      .to_return(status: 200, body: { data: { user: { stream: nil, broadcastSettings: { title: "Test", language: "en", game: nil } } } }.to_json,
                 headers: { "Content-Type" => "application/json" })

    expect { worker.perform(event_data) }.not_to change(Stream, :count)
    old_stream.reload
    expect(old_stream.merge_status).to eq("merged")
    # BUG-251.40 A2: merge refreshes twitch_stream_id to the latest broadcast id.
    expect(old_stream.twitch_stream_id).to eq("316159655126")
  end

  # ─── BUG-251.40 A2 — Fuse detection ─────────────────────────────────────────
  describe "BUG-251.40 A2: fuse detection (twitch_stream_id mismatch)" do
    # 2026-05-31 audit found 224 streams in this state on staging: open row from a
    # past broadcast, channel reconnected as a NEW Twitch broadcast, our detector
    # never closed the old row → today's CCV/chat written into yesterday's record.
    it "closes a stale (mismatched twitch_stream_id) open stream before creating new" do
      stale = create(:stream, channel: channel, ended_at: nil, twitch_stream_id: "999999999999")

      expect { worker.perform(event_data) }.to change(Stream, :count).by(1)

      stale.reload
      expect(stale.ended_at).to be_present
      expect(stale.ended_at).to be_within(5.seconds).of(Time.current)

      fresh = channel.streams.order(created_at: :desc).first
      expect(fresh.id).not_to eq(stale.id)
      expect(fresh.twitch_stream_id).to eq("316159655126")
      expect(fresh.ended_at).to be_nil
    end

    it "closes a legacy NULL-twitch_stream_id open stream before creating new (Phase A1 pre-existing rows)" do
      legacy = create(:stream, channel: channel, ended_at: nil, twitch_stream_id: nil)

      expect { worker.perform(event_data) }.to change(Stream, :count).by(1)

      legacy.reload
      expect(legacy.ended_at).to be_present

      fresh = channel.streams.order(created_at: :desc).first
      expect(fresh.id).not_to eq(legacy.id)
      expect(fresh.twitch_stream_id).to eq("316159655126")
    end

    it "stores twitch_stream_id from EventSub `id` key fallback when `stream_id` absent" do
      eventsub_payload = event_data.except("stream_id").merge("id" => "EVENTSUB123")
      expect { worker.perform(eventsub_payload) }.to change(Stream, :count).by(1)

      stream = channel.streams.order(created_at: :desc).first
      expect(stream.twitch_stream_id).to eq("EVENTSUB123")
    end

    it "is no-op when new broadcast matches existing open row (continuation, no churn)" do
      existing = create(:stream, channel: channel, ended_at: nil, twitch_stream_id: "316159655126")

      expect { worker.perform(event_data) }.not_to change(Stream, :count)
      existing.reload
      expect(existing.ended_at).to be_nil
    end

    it "preserves backward-compat when no stream_id/id is present (blank → channel-scoped check)" do
      legacy_payload = event_data.except("stream_id")
      create(:stream, channel: channel, ended_at: nil, twitch_stream_id: nil)

      # No incoming id → close_stale_if_fused is no-op → active_stream_exists? returns true → skip
      expect { worker.perform(legacy_payload) }.not_to change(Stream, :count)
    end

    # CR-237 C1 regression: the fuse-close + same-game-merge path used to re-open the
    # just-closed stale row, undoing the fuse fix. allow_merge:false gate prevents this.
    it "does NOT re-merge the just-closed stale row when game_name matches (CR-237 C1)" do
      stale = create(:stream, channel: channel, ended_at: nil,
                     twitch_stream_id: "999999999999",
                     game_name: "Just Chatting") # matches GQL stub default game

      expect { worker.perform(event_data) }.to change(Stream, :count).by(1)

      stale.reload
      expect(stale.ended_at).to be_present, "fuse-closed row must stay closed (CR-237 C1)"
      expect(stale.merge_status).not_to eq("merged"), "fuse path must NOT re-open the stale row even on game_name match"
      expect(stale.merged_parts_count).to eq(1), "merged_parts_count must NOT increment after fuse"

      fresh = channel.streams.where(twitch_stream_id: "316159655126").first
      expect(fresh).to be_present
      expect(fresh.id).not_to eq(stale.id)
      expect(fresh.ended_at).to be_nil
    end

    # CR-237 I1: legacy data can have >1 open Stream per channel (pre-A1 partial UNIQUE).
    # Fuse path must close ALL mismatched open rows, not just the most recent.
    it "closes ALL mismatched open streams when channel has multiple opens (CR-237 I1)" do
      stale1 = create(:stream, channel: channel, started_at: 2.days.ago, ended_at: nil,
                      twitch_stream_id: "OLD_BROADCAST_A", game_name: nil)
      stale2 = create(:stream, channel: channel, started_at: 1.day.ago, ended_at: nil,
                      twitch_stream_id: nil, game_name: nil) # NULL legacy

      expect { worker.perform(event_data) }.to change(Stream, :count).by(1)

      stale1.reload; stale2.reload
      expect(stale1.ended_at).to be_present, "first stale row must be closed"
      expect(stale2.ended_at).to be_present, "second stale row must be closed"
      expect(channel.streams.where(ended_at: nil).count).to eq(1)
      expect(channel.streams.where(ended_at: nil).first.twitch_stream_id).to eq("316159655126")
    end
  end
end
