# frozen_string_literal: true

require "rails_helper"

RSpec.describe SyncEventBatchWorker do
  let(:user) { create(:user) }
  let(:now) { Time.utc(2026, 5, 20, 12, 0, 0) }
  let(:event) do
    {
      "event_type" => "stream_view",
      "payload" => { "channel_id" => "12345", "watched_at" => now.iso8601, "duration_sec" => 60 },
      "device_fingerprint" => "device-1",
      "synced_at" => now.iso8601
    }
  end

  describe "#perform" do
    it "inserts new sync_event" do
      expect {
        described_class.new.perform(user.id, [event])
      }.to change(SyncEvent, :count).by(1)
    end

    it "is idempotent (same event submitted twice → 1 row)" do
      described_class.new.perform(user.id, [event])
      expect {
        described_class.new.perform(user.id, [event])
      }.not_to change(SyncEvent, :count)
    end

    it "skips invalid event_type" do
      invalid = event.merge("event_type" => "bogus")
      expect {
        described_class.new.perform(user.id, [invalid])
      }.not_to change(SyncEvent, :count)
    end

    it "skips empty events array" do
      expect {
        described_class.new.perform(user.id, [])
      }.not_to change(SyncEvent, :count)
    end
  end
end
