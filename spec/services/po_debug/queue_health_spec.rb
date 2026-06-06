# frozen_string_literal: true

require "rails_helper"

RSpec.describe PoDebug::QueueHealth do
  describe ".call" do
    it "returns global stats + per-queue rows derived from Sidekiq::Queue.all" do
      result = described_class.call

      expect(result).to include(:global, :queues)
      expect(result[:queues]).to be_an(Array)

      result[:queues].each do |q|
        expect(q).to include(:name, :depth, :latency_sec, :oldest_job_age_sec)
      end

      expect(result[:global]).to include(
        :processed_total, :failed_total, :enqueued,
        :scheduled, :retry_size, :dead_size,
        :throughput_jps, :processes, :workers_busy
      )
    end

    it "sorts queue rows by depth descending so worst is first" do
      result = described_class.call
      depths = result[:queues].map { |q| q[:depth] }
      expect(depths).to eq(depths.sort.reverse)
    end
  end
end
