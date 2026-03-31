# frozen_string_literal: true

require "rails_helper"

RSpec.describe StreamExpiringWorker do
  let(:channel) { create(:channel) }
  let(:stream) { create(:stream, channel: channel, started_at: 20.hours.ago, ended_at: 17.hours.ago) }

  before do
    allow(PostStreamNotificationService).to receive(:broadcast_stream_expiring)
  end

  describe "#perform" do
    it "broadcasts stream_expiring when window still open" do
      # ended_at = 17h ago → window closes at ended_at + 18h = 1h from now
      described_class.new.perform(stream.id)

      expect(PostStreamNotificationService).to have_received(:broadcast_stream_expiring).with(stream)
    end

    it "skips if channel is live" do
      create(:stream, channel: channel, started_at: 30.minutes.ago, ended_at: nil)

      described_class.new.perform(stream.id)

      expect(PostStreamNotificationService).not_to have_received(:broadcast_stream_expiring)
    end

    it "skips if window already expired" do
      old_stream = create(:stream, channel: channel, started_at: 30.hours.ago, ended_at: 20.hours.ago)

      described_class.new.perform(old_stream.id)

      expect(PostStreamNotificationService).not_to have_received(:broadcast_stream_expiring)
    end

    it "skips non-existent stream" do
      expect { described_class.new.perform("non-existent") }.not_to raise_error
      expect(PostStreamNotificationService).not_to have_received(:broadcast_stream_expiring)
    end
  end
end
