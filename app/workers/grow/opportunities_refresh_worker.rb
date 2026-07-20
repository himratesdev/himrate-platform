# frozen_string_literal: true

module Grow
  # Screen 13 «Рост» — computes the game-opportunity list per the PO spec (TASK-060 STREAMER-FINAL
  # Block 4): «новизна (растёт на Steam) + мало стримеров в категории (7-12, не 1000) + зрители
  # распределены (не топ-1 забрал всё)». Candidates = Steam new_releases (the novelty criterion is
  # the pool itself); each is matched to a Twitch category (Helix /games — most Steam releases have
  # none and are skipped) and measured live via /streams?game_id (streamer count + CCV distribution).
  #
  # ON-DEMAND, not cron: the endpoint warms this worker on a cold/stale cache (PENDING marker vs
  # enqueue storms) — zero recurring load (DSV §5), ~30 candidates × ≤2 Helix calls ≈ 45 calls/run,
  # ≤2 runs/day in practice. Sidekiq-only (HelixClient retry sleep). Cache 12h.
  class OpportunitiesRefreshWorker
    include Sidekiq::Worker
    sidekiq_options queue: :long_running, retry: 1

    CACHE_KEY = "grow:opportunities:v1"
    PENDING_KEY = "grow:opportunities:v1:pending"
    CACHE_TTL = 12.hours
    PENDING_TTL = 5.minutes
    TOP_N = 12
    IDEAL_STREAMERS = 10.0 # the PO's «7-12» band centre

    def perform
      candidates = SteamNewReleases.new.call
      return if candidates.empty? # Steam down → keep the stale cache, never blank the page

      helix = Twitch::HelixClient.new
      rows = candidates.filter_map { |candidate| measure(helix, candidate) }
      return if rows.empty?

      ranked = rows.sort_by { |r| -r[:growth_score] }.first(TOP_N)
      Rails.cache.write(CACHE_KEY, { "generated_at" => Time.current.iso8601, "games" => ranked.as_json },
                        expires_in: CACHE_TTL)
    ensure
      Rails.cache.delete(PENDING_KEY)
    end

    private

    def measure(helix, candidate)
      game = helix.get_game(name: candidate[:name])
      return nil unless game # most Steam releases have no Twitch category yet — honest skip

      streams = helix.get_streams_by_game(game_id: game["id"])
      ccvs = streams.map { |s| s["viewer_count"].to_i }.sort.reverse
      total = ccvs.sum
      return nil if streams.empty? || total.zero? # no live demand signal → not an opportunity

      top1_share = (ccvs.first.to_f / total).round(3)
      scarcity = scarcity_score(streams.size)
      distribution = (1.0 - top1_share).round(3)
      demand = demand_score(total)

      {
        name: game["name"],
        twitch_game_id: game["id"],
        steam_id: candidate[:steam_id],
        box_art_url: game["box_art_url"],
        live_streamers: streams.size,
        total_ccv: total,
        median_ccv: ccvs[ccvs.size / 2],
        top1_share_pct: (top1_share * 100).round(1),
        is_steam_new_release: true,
        scarcity_score: scarcity,
        distribution_score: distribution,
        demand_score: demand,
        # geometric mean — an opportunity needs ALL three of the PO's criteria at once
        growth_score: (scarcity * distribution * demand)**(1.0 / 3) .round(3)
      }
    end

    # Peaks at the PO's 7-12 band; falls off toward 0 (dead category) and 100+ (saturated).
    def scarcity_score(streamers)
      (1.0 - ((streamers - IDEAL_STREAMERS).abs / 60.0)).clamp(0.05, 1.0).round(3)
    end

    # Log-scaled viewer demand: 100 CCV ≈ 0.5, 10k+ CCV → 1.0.
    def demand_score(total_ccv)
      (Math.log10([ total_ccv, 1 ].max) / 4.0).clamp(0.0, 1.0).round(3)
    end
  end
end
