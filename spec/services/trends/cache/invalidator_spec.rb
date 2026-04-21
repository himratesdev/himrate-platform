# frozen_string_literal: true

require "rails_helper"

RSpec.describe Trends::Cache::Invalidator do
  let(:channel_id) { "00000000-0000-0000-0000-000000000001" }

  describe ".call" do
    let(:redis_double) { instance_double(Redis) }

    before do
      allow(Redis).to receive(:new).and_return(redis_double)
      allow(redis_double).to receive(:close)
    end

    it "increments per-channel epoch в Redis" do
      allow(redis_double).to receive(:incr).with("trends:epoch:#{channel_id}").and_return(1)

      result = described_class.call(channel_id)

      expect(result).to eq(1)
      expect(redis_double).to have_received(:incr).with("trends:epoch:#{channel_id}")
    end

    it "emits trends.cache.invalidated notification" do
      allow(redis_double).to receive(:incr).and_return(5)
      captured = []
      subscription = ActiveSupport::Notifications.subscribe("trends.cache.invalidated") do |*args|
        captured << ActiveSupport::Notifications::Event.new(*args)
      end

      begin
        described_class.call(channel_id)
      ensure
        ActiveSupport::Notifications.unsubscribe(subscription)
      end

      expect(captured.size).to eq(1)
      expect(captured.first.payload[:channel_id]).to eq(channel_id)
      expect(captured.first.payload[:new_epoch]).to eq(5)
    end

    it "gracefully handles Redis failure" do
      allow(redis_double).to receive(:incr).and_raise(Redis::CannotConnectError.new("connection refused"))
      expect(Rails.error).to receive(:report).with(
        instance_of(Redis::CannotConnectError),
        hash_including(context: hash_including(channel_id: channel_id), handled: true)
      )
      expect(Rails.logger).to receive(:warn).with(/Invalidator.*channel=#{channel_id}.*connection refused/)

      result = described_class.call(channel_id)
      expect(result).to be_nil
    end
  end
end
