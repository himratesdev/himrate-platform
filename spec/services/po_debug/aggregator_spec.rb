# frozen_string_literal: true

require "rails_helper"

RSpec.describe PoDebug::Aggregator do
  describe ".call" do
    before do
      Rails.cache.clear
      # Stub collectors that hit external services / live data so the spec
      # is hermetic. The aggregator behavior (orchestration + error-isolation
      # + caching) is the unit under test, not individual collectors.
      allow(PoDebug::StreamState).to receive(:call).and_return({ state: "stub_stream" })
      allow(PoDebug::PipelineActivity).to receive(:call).and_return({ stub: true })
      allow(PoDebug::ViewerBreakdown).to receive(:call).and_return({ stub: true })
      allow(PoDebug::QueueHealth).to     receive(:call).and_return({ stub_queues: true })
      allow(PoDebug::VpsHealth).to       receive(:call).and_return({ stub_vps: true })
      allow(PoDebug::WritesLog).to       receive(:call).and_return({ stub: true })
      allow(PoDebug::ErrorsLog).to       receive(:call).and_return({ stub: true })
    end

    it "returns all 7 block keys + meta" do
      snapshot = described_class.call

      expect(snapshot).to include(
        :generated_at, :version,
        :stream, :pipeline, :viewers, :queues, :vps, :writes_log, :errors
      )
      expect(snapshot[:version]).to eq("v0.1-hot-lite")
    end

    it "isolates collector failures — one error does not break sibling blocks" do
      allow(PoDebug::StreamState).to receive(:call).and_raise("boom")

      snapshot = described_class.call

      expect(snapshot[:stream]).to include(error: a_string_matching(/boom/), stale: true)
      expect(snapshot[:queues]).to eq(stub_queues: true)
      expect(snapshot[:vps]).to eq(stub_vps: true)
    end

    it "caches the snapshot for CACHE_TTL between calls" do
      first = described_class.call
      second = described_class.call
      expect(second[:generated_at]).to eq(first[:generated_at])
    end

    it "regenerates after Rails.cache.delete" do
      first = described_class.call
      Rails.cache.delete("po_debug:snapshot:v1")
      sleep 1.1
      second = described_class.call
      expect(second[:generated_at]).not_to eq(first[:generated_at])
    end
  end
end
