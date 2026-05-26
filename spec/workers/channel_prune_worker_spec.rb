# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChannelPruneWorker do
  let(:worker) { described_class.new }

  before do
    allow(Flipper).to receive(:enabled?).with(:stream_monitor).and_return(true)
    allow(Flipper).to receive(:enabled?).with(:channel_prune).and_return(true)
  end

  def banned_channel(twitch_id:, login:)
    # monitored + non-pinned + metadata synced + display_name blank = Helix returned nothing
    create(:channel, twitch_id: twitch_id, login: login, display_name: nil, is_monitored: true, is_pinned: false)
      .tap { |c| c.update_columns(metadata_synced_at: 1.hour.ago) }
  end

  it "unmonitors banned non-pinned channels (synced + blank display_name)" do
    banned = banned_channel(twitch_id: "1", login: "ghostchan")

    worker.perform

    expect(banned.reload.is_monitored).to be(false)
  end

  it "never prunes pinned channels" do
    pinned = create(:channel, twitch_id: "2", login: "curated", display_name: nil, is_monitored: true, is_pinned: true)
    pinned.update_columns(metadata_synced_at: 1.hour.ago)

    worker.perform

    expect(pinned.reload.is_monitored).to be(true)
  end

  it "keeps channels that have a display_name (real, resolved by Helix)" do
    real = create(:channel, twitch_id: "3", login: "realstreamer", display_name: "RealStreamer", is_monitored: true, is_pinned: false)
    real.update_columns(metadata_synced_at: 1.hour.ago)

    worker.perform

    expect(real.reload.is_monitored).to be(true)
  end

  it "keeps not-yet-synced channels (metadata_synced_at NULL) — banned status unconfirmed" do
    unsynced = create(:channel, twitch_id: "4", login: "pending", display_name: nil, is_monitored: true, is_pinned: false)
    unsynced.update_columns(metadata_synced_at: nil)

    worker.perform

    expect(unsynced.reload.is_monitored).to be(true)
  end

  it "ignores already-unmonitored channels (idempotent)" do
    create(:channel, twitch_id: "5", login: "gone", display_name: nil, is_monitored: false, is_pinned: false)
      .update_columns(metadata_synced_at: 1.hour.ago)

    expect { worker.perform }.not_to raise_error
    expect(Channel.where(twitch_id: "5").first.is_monitored).to be(false)
  end

  it "is bounded by MAX_PER_RUN per run" do
    stub_const("ChannelPruneWorker::MAX_PER_RUN", 1)
    banned_channel(twitch_id: "10", login: "g1")
    banned_channel(twitch_id: "11", login: "g2")

    worker.perform

    expect(Channel.monitored.where(twitch_id: %w[10 11]).count).to eq(1) # only 1 pruned this run
  end

  it "does nothing when :channel_prune is disabled (kill-switch)" do
    allow(Flipper).to receive(:enabled?).with(:channel_prune).and_return(false)
    banned = banned_channel(twitch_id: "6", login: "ghost2")

    worker.perform

    expect(banned.reload.is_monitored).to be(true)
  end

  it "does nothing when :stream_monitor is disabled" do
    allow(Flipper).to receive(:enabled?).with(:stream_monitor).and_return(false)
    banned = banned_channel(twitch_id: "7", login: "ghost3")

    worker.perform

    expect(banned.reload.is_monitored).to be(true)
  end

  describe "#preview (dry-run)" do
    it "reports the eligible count without mutating" do
      banned = banned_channel(twitch_id: "8", login: "ghost4")

      result = worker.preview

      expect(result[:count]).to eq(1)
      expect(result[:sample]).to include("ghost4")
      expect(banned.reload.is_monitored).to be(true) # no mutation
    end
  end
end
