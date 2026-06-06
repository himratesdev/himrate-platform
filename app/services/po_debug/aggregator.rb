# frozen_string_literal: true

module PoDebug
  # Aggregator orchestrates all 7 collectors and merges them into a single
  # snapshot. Each block is collected in isolation — a failure in one block
  # surfaces as `{ error: "..." }` for that block and does NOT prevent the
  # other 6 from rendering.
  #
  # Cached for CACHE_TTL (5s) in Rails.cache, keyed globally (single PO client).
  class Aggregator
    BLOCKS = %i[stream pipeline viewers queues vps writes_log errors].freeze

    def self.call(force: false)
      new.call(force: force)
    end

    def call(force: false)
      key = "po_debug:snapshot:v1"
      Rails.cache.delete(key) if force
      Rails.cache.fetch(key, expires_in: PoDebug::CACHE_TTL) do
        build_snapshot
      end
    end

    private

    def build_snapshot
      snapshot = { generated_at: Time.current.iso8601, version: "v0.1-hot-lite" }
      BLOCKS.each do |block|
        snapshot[block] = collect(block)
      end
      snapshot
    end

    def collect(block)
      klass = collector_for(block)
      klass.call
    rescue StandardError => e
      Rails.logger.tagged("po_debug").warn("collector #{block} failed: #{e.class}: #{e.message}")
      { error: "#{e.class}: #{e.message}", stale: true }
    end

    def collector_for(block)
      case block
      when :stream      then PoDebug::StreamState
      when :pipeline    then PoDebug::PipelineActivity
      when :viewers     then PoDebug::ViewerBreakdown
      when :queues      then PoDebug::QueueHealth
      when :vps         then PoDebug::VpsHealth
      when :writes_log  then PoDebug::WritesLog
      when :errors      then PoDebug::ErrorsLog
      end
    end
  end
end
