# frozen_string_literal: true

module Graph
  # Keeps the «Паутинка» full-graph payload warm.
  #
  # The graph is a compute-on-read aggregate over the ClickHouse presence layer: a pairwise
  # self-join across ~200 channels and their shared chatters. That is genuinely heavy work (tens of
  # seconds on the current corpus) — acceptable to pay in the background every so often, NOT
  # acceptable to hand to whoever opens the page first after a cache expiry. This worker recomputes
  # it on a schedule and writes it under the same key the request path reads, so a page load is
  # always a cache hit.
  #
  # Deliberately only the FULL graph: ego views are per-channel and unbounded in count, so they stay
  # on-demand behind their own short cache.
  class CacheWarmWorker
    include Sidekiq::Job
    sidekiq_options queue: :long_running, retry: 1

    # Longer than the refresh cadence so the entry never expires between two runs (a miss would
    # push the cost back onto a request).
    CACHE_TTL = 3.hours

    def perform
      started = Time.current
      payload = AudienceGraphService.new.build
      Rails.cache.write(AudienceGraphService::FULL_CACHE_KEY, payload, expires_in: CACHE_TTL)

      Rails.logger.info(
        "Graph::CacheWarmWorker: warmed full graph (#{payload[:nodes]&.size} nodes, " \
        "#{payload[:edges]&.size} edges) in #{(Time.current - started).round(1)}s"
      )
    end
  end
end
