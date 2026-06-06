# frozen_string_literal: true

require "rails_helper"

RSpec.describe PoDebug::QueueHealth do
  describe ".call" do
    it "returns global stats + per-queue rows for the canonical queue list" do
      result = described_class.call

      expect(result).to include(:global, :queues)
      expect(result[:queues]).to be_an(Array)

      queue_names = result[:queues].map { |q| q[:name] }
      expect(queue_names).to include(*described_class::QUEUES)

      result[:queues].each do |q|
        expect(q).to include(:name, :depth, :latency_sec, :oldest_job_age_sec)
      end

      expect(result[:global]).to include(
        :processed_total, :failed_total, :enqueued,
        :scheduled, :retry_size, :dead_size,
        :throughput_jps, :processes, :workers_busy
      )
    end
  end
end
