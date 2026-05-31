# frozen_string_literal: true

require "rails_helper"

RSpec.describe Streams::LifecycleAudit do
  let(:helix) { instance_double(Twitch::HelixClient) }
  let(:logger) { instance_double(Logger, info: nil, warn: nil, error: nil) }

  before do
    allow(Twitch::HelixClient).to receive(:new).and_return(helix)
    # Skip the inter-close sleep in specs (would add seconds per fuse/ghost).
    stub_const("Streams::LifecycleAudit::INTER_CLOSE_SLEEP_SEC", 0)
  end

  def open_stream(channel:, started_at: 24.hours.ago, twitch_stream_id: nil)
    create(:stream, channel: channel, started_at: started_at, ended_at: nil, twitch_stream_id: twitch_stream_id)
  end

  describe "#classify" do
    it "splits open streams into fuse / ghost / ok based on Helix response" do
      fused_ch  = create(:channel, twitch_id: "111", login: "fused_streamer")
      ghost_ch  = create(:channel, twitch_id: "222", login: "ghosted")
      ok_ch     = create(:channel, twitch_id: "333", login: "real_24h")

      open_stream(channel: fused_ch,  twitch_stream_id: "OLD_BROADCAST_ID")
      open_stream(channel: ghost_ch,  twitch_stream_id: "OLD_GHOST_ID")
      open_stream(channel: ok_ch,     twitch_stream_id: "MATCHING_ID")

      allow(helix).to receive(:get_streams).and_return([
        { "user_id" => "111", "id" => "NEW_BROADCAST_ID", "started_at" => "2026-05-31T10:00:00Z", "game_name" => "Counter-Strike" },
        { "user_id" => "333", "id" => "MATCHING_ID",     "started_at" => "2026-05-30T13:00:00Z", "game_name" => "Just Chatting" }
        # 222 absent — Helix shows offline → ghost
      ])

      data = described_class.new(dry_run: true, logger: logger).audit_only

      expect(data[:fuse].size).to eq(1)
      expect(data[:fuse].first).to include(login: "fused_streamer", our_tws: "OLD_BROADCAST_ID", helix_id: "NEW_BROADCAST_ID")

      expect(data[:ghost].size).to eq(1)
      expect(data[:ghost].first).to include(login: "ghosted")

      expect(data[:ok].size).to eq(1)
      expect(data[:ok].first).to include(login: "real_24h")
    end

    it "classifies legacy NULL twitch_stream_id as FUSE (Phase A1 pre-existing rows)" do
      legacy_ch = create(:channel, twitch_id: "111", login: "legacy")
      open_stream(channel: legacy_ch, twitch_stream_id: nil)

      allow(helix).to receive(:get_streams).and_return([
        { "user_id" => "111", "id" => "ANY_NEW_ID", "started_at" => "2026-05-31T10:00:00Z", "game_name" => "Just Chatting" }
      ])

      data = described_class.new(dry_run: true, logger: logger).audit_only
      expect(data[:fuse].size).to eq(1)
      expect(data[:ghost]).to be_empty
      expect(data[:ok]).to be_empty
    end

    it "ignores streams younger than MIN_AGE_HOURS" do
      ch = create(:channel, twitch_id: "111")
      open_stream(channel: ch, started_at: 1.hour.ago) # below default 12h threshold

      allow(helix).to receive(:get_streams).and_return([])
      data = described_class.new(dry_run: true, logger: logger).audit_only
      expect(data[:fuse] + data[:ghost] + data[:ok]).to be_empty
    end

    it "respects partial Helix batch failure (failed batch → channels logged but classified as GHOST candidates)" do
      ch_in_failed = create(:channel, twitch_id: "222", login: "in_failed_batch")
      open_stream(channel: ch_in_failed)

      stub_const("MonitoredLiveDetectorWorker::HELIX_BATCH_SIZE", 1)
      allow(helix).to receive(:get_streams) { |user_ids:| user_ids == [ "222" ] ? nil : [] }
      expect(logger).to receive(:warn).with(/Helix sub-batch.*failed/)

      data = described_class.new(dry_run: true, logger: logger).audit_only
      # Failed-batch channels still appear in classify output as GHOST, BUT operator was
      # warned (see warn-log above) so they understand the data may be transient.
      expect(data[:ghost].size).to eq(1)
    end
  end

  describe "#call" do
    let(:ch) { create(:channel, twitch_id: "111", login: "stale_streamer") }

    before { @stale = open_stream(channel: ch, twitch_stream_id: "OLD") }

    it "dry_run=true does NOT close any stream" do
      allow(helix).to receive(:get_streams).and_return([])
      expect(StreamOfflineWorker).not_to receive(:new)

      described_class.new(dry_run: true, logger: logger).call

      expect(Stream.where(channel: ch, ended_at: nil).count).to eq(1)
    end

    it "dry_run=false closes fuse rows" do
      allow(helix).to receive(:get_streams).and_return([
        { "user_id" => "111", "id" => "NEW", "started_at" => "2026-05-31T10:00:00Z", "game_name" => "X" }
      ])

      offline_worker = instance_double(StreamOfflineWorker)
      allow(StreamOfflineWorker).to receive(:new).and_return(offline_worker)
      expect(offline_worker).to receive(:perform).with(
        { "broadcaster_user_id" => "111", "broadcaster_user_login" => "stale_streamer" },
        "lifecycle_audit"
      )

      described_class.new(dry_run: false, logger: logger).call
    end

    it "dry_run=false closes ghost rows" do
      allow(helix).to receive(:get_streams).and_return([]) # channel absent = ghost

      offline_worker = instance_double(StreamOfflineWorker)
      allow(StreamOfflineWorker).to receive(:new).and_return(offline_worker)
      expect(offline_worker).to receive(:perform).with(
        { "broadcaster_user_id" => "111", "broadcaster_user_login" => "stale_streamer" },
        "lifecycle_audit"
      )

      described_class.new(dry_run: false, logger: logger).call
    end

    it "dry_run=false leaves OK rows alone" do
      ok_ch = create(:channel, twitch_id: "999", login: "real_24h")
      open_stream(channel: ok_ch, twitch_stream_id: "MATCH")

      # Two channels in DB: stale + real. Helix shows real as live with matching id.
      allow(helix).to receive(:get_streams).and_return([
        { "user_id" => "999", "id" => "MATCH", "started_at" => "2026-05-30T13:00:00Z", "game_name" => "Just Chatting" }
      ])

      offline_worker = instance_double(StreamOfflineWorker)
      allow(StreamOfflineWorker).to receive(:new).and_return(offline_worker)
      # Only stale gets closed (ghost — Helix offline for 111); real_24h is OK
      expect(offline_worker).to receive(:perform).with(
        hash_including("broadcaster_user_login" => "stale_streamer"), "lifecycle_audit"
      ).once

      described_class.new(dry_run: false, logger: logger).call
    end

    # CR-238 Important #1
    it "REFUSES to apply when any Helix sub-batch failed (CR-238 #1)" do
      stub_const("MonitoredLiveDetectorWorker::HELIX_BATCH_SIZE", 1)
      allow(helix).to receive(:get_streams).and_return(nil) # all batches fail

      expect(StreamOfflineWorker).not_to receive(:new)
      expect(logger).to receive(:info).with(/REFUSING to apply/).at_least(:once)

      described_class.new(dry_run: false, logger: logger).call
      # Stale row stays open — operator must re-run after Helix recovers.
      expect(Stream.where(ended_at: nil, channel: ch).count).to eq(1)
    end

    # CR-238 Important #2
    it "SKIPS close when stream was already finalized between classify and close_all" do
      allow(helix).to receive(:get_streams).and_return([
        { "user_id" => "111", "id" => "NEW", "started_at" => "2026-05-31T10:00:00Z", "game_name" => "X" }
      ])

      # Simulate race: EventSub closes the stale row between classify and close_all.
      allow(Stream).to receive(:find_by).and_wrap_original do |orig, **args|
        row = orig.call(**args)
        row&.update_columns(ended_at: Time.current) if row && row.id == @stale.id
        row.reload if row
        row
      end

      expect(StreamOfflineWorker).not_to receive(:new)

      described_class.new(dry_run: false, logger: logger).call
    end

    it "SKIPS close when a replacement stream opened between classify and close_all" do
      allow(helix).to receive(:get_streams).and_return([
        { "user_id" => "111", "id" => "NEW", "started_at" => "2026-05-31T10:00:00Z", "game_name" => "X" }
      ])

      # Replacement opens BETWEEN classify and close.
      replacement = nil
      allow(Stream).to receive(:find_by).and_wrap_original do |orig, **args|
        row = orig.call(**args)
        # On first call from classify: this returns the stale row. Race happens after.
        # On second call (in close_one): the row still exists open BUT a NEWER open row exists.
        if row && row.id == @stale.id && replacement.nil?
          replacement = create(:stream, channel: ch, ended_at: nil, twitch_stream_id: "NEW",
                                started_at: Time.current)
        end
        row
      end

      expect(StreamOfflineWorker).not_to receive(:new)

      described_class.new(dry_run: false, logger: logger).call
    end

    # CR-238 nice #3 — exception isolation
    it "continues batch on a single close failure (per-row rescue)" do
      ch2 = create(:channel, twitch_id: "222", login: "second_stale")
      open_stream(channel: ch2, twitch_stream_id: "OTHER_OLD")

      allow(helix).to receive(:get_streams).and_return([
        { "user_id" => "111", "id" => "NEW1", "started_at" => "2026-05-31T10:00:00Z", "game_name" => "X" },
        { "user_id" => "222", "id" => "NEW2", "started_at" => "2026-05-31T10:00:00Z", "game_name" => "Y" }
      ])

      offline_worker = instance_double(StreamOfflineWorker)
      allow(StreamOfflineWorker).to receive(:new).and_return(offline_worker)
      expect(offline_worker).to receive(:perform).twice do |payload, _src|
        raise StandardError, "transient redis err" if payload["broadcaster_user_login"] == "stale_streamer"
        nil
      end

      # Both attempted, first errored, second succeeded.
      described_class.new(dry_run: false, logger: logger).call
    end
  end
end
