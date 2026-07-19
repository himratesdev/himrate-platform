# frozen_string_literal: true

module Brand
  # Screen 23 — Brand Compare. Side-by-side comparison of 2-4 streamers by REAL 30-day audience
  # (not shown viewers), normalizing an optional brand-supplied integration price into "price per
  # real viewer". Reuses Brand::AudienceWindow (same 30-day aggregate as the streamer card #348 —
  # no-drift) and Reputation::HistoryService. Compute-on-read, no mocks: a channel with no window
  # data reports audience.available:false; price rows appear only when the brand supplies prices;
  # unique-reach / engagement-rate are deferred (no honest per-channel source).
  class CompareService
    MIN_CHANNELS = 2
    MAX_CHANNELS = 4
    # Bands a brand can safely recommend against (audience reality is dependable).
    RECOMMENDABLE_BANDS = %w[impeccable stable].freeze
    # Ordinal for best-reliability highlighting (higher = more dependable). nil band → excluded.
    BAND_RANK = { "impeccable" => 4, "stable" => 3, "variable" => 2, "unstable" => 1 }.freeze
    DEFERRED = %w[unique_reach engagement_rate export].freeze
    Result = Struct.new(:ok, :error, :payload, keyword_init: true)

    def initialize(logins:, prices: [])
      # Pair each login with its POSITIONAL price BEFORE de-duplicating, then key prices by login —
      # so a duplicate login can't shift subsequent prices out of alignment (CR SHOULD-FIX). First
      # occurrence of a login wins.
      raw_prices = Array(prices)
      @price_by_login = {}
      Array(logins).each_with_index do |login, i|
        key = login.to_s.strip.downcase
        next if key.blank? || @price_by_login.key?(key)

        @price_by_login[key] = parse_price(raw_prices[i])
      end
      @logins = @price_by_login.keys
    end

    def call
      return Result.new(ok: false, error: "CHANNELS_REQUIRED") unless @logins.size.between?(MIN_CHANNELS, MAX_CHANNELS)

      channels = @logins.map { |login| Channel.active.find_by("lower(login) = ?", login) }
      return Result.new(ok: false, error: "CHANNEL_NOT_FOUND") if channels.any?(&:nil?)

      Result.new(ok: true, payload: build(channels))
    end

    private

    def build(channels)
      columns = channels.map { |channel| column(channel) }
      {
        window: { days: AudienceWindow::DEFAULT_DAYS },
        channels: columns,
        best_in_row: best_in_row(columns),
        recommendation: recommendation(columns),
        deferred: DEFERRED
      }
    end

    def column(channel)
      win = AudienceWindow.new(channel)
      audience = win.audience.merge(streams_per_week: win.streams_per_week)
      current = (Reputation::HistoryService.cached_for(channel)[:current] || {})
      stream = channel.streams.order(started_at: :desc).first
      {
        login: channel.login,
        display_name: channel.display_name,
        category: stream&.game_name,
        audience: audience,
        reputation: {
          band: current[:band],
          band_label_ru: Brand::ReputationBands.label_ru(current[:band]),
          tier: current[:tier]
        },
        price: price_block(@price_by_login[channel.login], audience[:real_avg_viewers])
      }
    end

    def price_block(price, real_avg)
      return nil if price.nil?

      per_real = real_avg && real_avg.positive? ? (price.to_f / real_avg).round(1) : nil
      { per_integration: price, per_real_viewer: per_real }
    end

    # Positive integer RUB, or nil for a blank/invalid slot (→ that channel has no price row).
    # Integer(exception:false) rejects decimals cleanly instead of silently truncating (CR nit).
    def parse_price(raw)
      return nil if raw.nil? || raw.to_s.strip.blank?

      value = Integer(raw.to_s.strip, exception: false)
      value&.positive? ? value : nil
    end

    # login of the winning channel per RENDERED design row (frontend greens that cell). Columns
    # missing a value (cold-start audience / no price) are ignored, not treated as zero. Keys match
    # the design's highlighted comparison rows (SRS §4A): Реальные зрители / Доля реальных /
    # Надёжность (band, ordinal) / Частота эфиров / Цена за реального. TI is filter-only (no row).
    def best_in_row(columns)
      {
        real_avg_viewers: argmax(columns) { |c| c[:audience][:real_avg_viewers] },
        real_pct: argmax(columns) { |c| c[:audience][:real_pct] },
        band: argmax(columns) { |c| BAND_RANK[c[:reputation][:band]] },
        streams_per_week: argmax(columns) { |c| c[:audience][:streams_per_week] },
        price_per_real_viewer: argmin(columns) { |c| c.dig(:price, :per_real_viewer) }
      }
    end

    # Cheapest price-per-real-viewer among channels with a dependable band + real audience + a price.
    def recommendation(columns)
      eligible = columns.select do |c|
        RECOMMENDABLE_BANDS.include?(c[:reputation][:band]) &&
          c[:audience][:available] &&
          c.dig(:price, :per_real_viewer)
      end
      best = eligible.min_by { |c| c[:price][:per_real_viewer] }
      return nil unless best

      {
        login: best[:login],
        reason: "lowest_price_per_real_viewer_recommendable_band",
        per_real_viewer: best[:price][:per_real_viewer]
      }
    end

    def argmax(columns)
      scored = columns.filter_map { |c| (v = yield(c)) && [ c[:login], v ] }
      scored.max_by(&:last)&.first
    end

    def argmin(columns)
      scored = columns.filter_map { |c| (v = yield(c)) && [ c[:login], v ] }
      scored.min_by(&:last)&.first
    end
  end
end
