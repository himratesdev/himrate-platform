# frozen_string_literal: true

require "rails_helper"

RSpec.describe Streams::LifecycleAudit do
  let(:helix) { instance_double(Twitch::HelixClient) }
  let(:logger) { instance_double(Logger, info: nil, warn: nil) }

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

    before { open_stream(channel: ch, twitch_stream_id: "OLD") }

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
  end
end
