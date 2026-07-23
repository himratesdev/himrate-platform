# frozen_string_literal: true

module Brand
  # Screen 20 — Brand streamer search/discovery. Ranks the whole channel population by REAL 30-day
  # audience (ccv_avg × erv%, not shown viewers) with filters, over trends_daily_aggregates.
  #
  # Scale (A1, PO-chosen 2026-07-19): ONE aggregate GROUP BY channel_id over the 30-day slice
  # (indexed channel_id+date) + latest-classification/language subqueries + LIMIT/OFFSET — no
  # per-channel AudienceWindow calls, no new worker. Correct to ~10k channels. A materialized
  # search index + refresh worker (A2, for 100k+ / band-filter) is the flagged future upgrade.
  #
  # Two-phase: (1) aggregate → filtered/sorted/paginated channel_ids + metrics; (2) batch-enrich the
  # page (<= per_page channels) with meta/category/language/label — N+1-free.
  class StreamerSearchQuery
    WINDOW_DAYS = 30
    DEFAULT_PER_PAGE = 20
    MAX_PER_PAGE = 50
    CLASSIFICATIONS = %w[trusted needs_review suspicious fraudulent].freeze
    # streams-per-week buckets (design: Ежедневно / 3–5 / 1–2)
    FREQUENCY_BUCKETS = { "daily" => [ 7.0, nil ], "3_5" => [ 3.0, 7.0 ], "1_2" => [ 1.0, 3.0 ] }.freeze
    SORTS = { "real_avg" => "real_avg", "real_pct" => "real_pct", "streams_per_week" => "spw" }.freeze
    DEFERRED = %w[band_filter price format saved_search].freeze
    # SA-2: creators can now be filtered by a linked social platform, backed by the channel_social_links
    # footprint index (Social::FootprintIndexWorker). The chip set = the analyzable platforms.
    PLATFORMS = SocialAnalytics::TwitchSocials::ANALYZABLE

    # PR3b (T1-074, M11b): COALESCE = transition-safe mixed-window aggregation — v2 TDA rows carry
    # the native real-viewer count (erv_avg_count) and authenticity_avg; pre-cutover rows fall back
    # to the v1 derivation. Data-driven (no flag branch), same pattern as the reputation CASE-port.
    REAL_EXPR  = "AVG(COALESCE(erv_avg_count, ccv_avg * erv_avg_percent / 100.0))"
    SHOWN_EXPR = "AVG(ccv_avg)"
    SPW_EXPR   = "SUM(streams_count) * 7.0 / #{WINDOW_DAYS}"
    # real as % of shown (audience-reality %), guarded against 0 shown
    REAL_PCT_EXPR = "CASE WHEN #{SHOWN_EXPR} > 0 THEN #{REAL_EXPR} / #{SHOWN_EXPR} * 100 ELSE 0 END"

    def initialize(params)
      @category = params[:category].presence
      @language = params[:language].presence
      @platform = PLATFORMS.include?(params[:platform].to_s) ? params[:platform].to_s : nil
      @min_real = params[:min_real].presence && params[:min_real].to_i
      @frequency = FREQUENCY_BUCKETS.key?(params[:frequency].to_s) ? params[:frequency].to_s : nil
      @classification = params[:classification].to_s.split(",").map(&:strip).select { |c| CLASSIFICATIONS.include?(c) }.presence
      @sort = SORTS.key?(params[:sort].to_s) ? params[:sort].to_s : "real_avg"
      @page = [ params[:page].to_i, 1 ].max
      @per_page = params[:per_page].present? ? params[:per_page].to_i.clamp(1, MAX_PER_PAGE) : DEFAULT_PER_PAGE
    end

    def call
      scope = filtered_grouped
      total = scope.count.size # grouped .count → {channel_id => n}; .size = matching channels

      rows = scope
             .select("channel_id, #{REAL_EXPR} AS real_avg, #{SHOWN_EXPR} AS shown_avg, " \
                     "#{REAL_PCT_EXPR} AS real_pct, AVG(COALESCE(authenticity_avg, ti_avg)) AS ti_avg, #{SPW_EXPR} AS spw")
             .order(Arel.sql("#{sort_expr} DESC NULLS LAST, channel_id ASC")) # channel_id = stable tiebreaker (deterministic pagination on ties)
             .limit(@per_page).offset((@page - 1) * @per_page)
             .to_a

      { results: enrich(rows), total: total, page: @page, per_page: @per_page, sort: @sort, deferred: DEFERRED }
    end

    private

    def window
      @window ||= WINDOW_DAYS.days.ago.to_date..Date.current
    end

    # Grouped relation with all structural filters + HAVING applied (shared by count + page).
    def filtered_grouped
      scope = TrendsDailyAggregate.where(date: window)
      scope = scope.where("categories ? :cat", cat: @category) if @category
      scope = scope.where(channel_id: language_channel_ids) if @language
      scope = scope.where(channel_id: platform_channel_ids) if @platform
      scope = scope.where(channel_id: classification_channel_ids) if @classification
      scope = scope.group(:channel_id)
      scope = scope.having("#{REAL_EXPR} >= ?", @min_real) if @min_real
      scope = apply_frequency(scope) if @frequency
      scope
    end

    def apply_frequency(scope)
      low, high = FREQUENCY_BUCKETS[@frequency]
      scope = scope.having("#{SPW_EXPR} >= ?", low)
      scope = scope.having("#{SPW_EXPR} < ?", high) if high
      scope
    end

    def sort_expr
      case @sort
      when "real_pct" then REAL_PCT_EXPR
      when "streams_per_week" then SPW_EXPR
      else REAL_EXPR
      end
    end

    # channel_ids that link the given social platform (SA-2 footprint index — index-served on
    # channel_social_links.platform). IN dedupes the (rare) two-links-same-platform case.
    def platform_channel_ids
      ChannelSocialLink.on_platform(@platform).select(:channel_id)
    end

    # channel_ids whose LATEST stream language matches (DISTINCT ON latest per channel).
    def language_channel_ids
      latest = Stream.select("DISTINCT ON (channel_id) channel_id, language")
                     .order("channel_id, started_at DESC")
      Stream.from(latest, :s).where(s: { language: @language }).select(:channel_id)
    end

    # channel_ids whose LATEST in-window verdict is one of the wanted set. PR3b: v2 TDA rows carry
    # band_color_at_end instead of classification_at_end — map the legacy classification params onto
    # band colors so the filter spans mixed windows (trusted→green, needs_review→yellow+amber,
    # suspicious→amber+yellow, fraudulent→red; grey = insufficient, excluded by any filter).
    CLASSIFICATION_TO_BANDS = {
      "trusted" => %w[green], "needs_review" => %w[yellow amber],
      "suspicious" => %w[amber yellow], "fraudulent" => %w[red]
    }.freeze

    def classification_channel_ids
      bands = @classification.flat_map { |c| CLASSIFICATION_TO_BANDS.fetch(c, []) }.uniq
      latest = TrendsDailyAggregate.where(date: window)
                                   .select("DISTINCT ON (channel_id) channel_id, classification_at_end, band_color_at_end")
                                   .order("channel_id, date DESC")
      TrendsDailyAggregate.from(latest, :t)
                          .where("t.classification_at_end IN (:cls) OR t.band_color_at_end IN (:bands)",
                                 cls: @classification, bands: bands)
                          .select(:channel_id)
    end

    # Phase 2 — batch-enrich the page (<= per_page channels), preserving aggregate order. No N+1.
    def enrich(rows)
      ids = rows.map { |r| r.channel_id }
      return [] if ids.empty?

      channels = Channel.where(id: ids).index_by(&:id)
      latest_streams = latest_streams_by_channel(ids)
      classifications = latest_classification_by_channel(ids)

      rows.filter_map do |r|
        channel = channels[r.channel_id]
        next unless channel

        stream = latest_streams[r.channel_id]
        real_avg = r.real_avg.round
        shown_avg = r.shown_avg.round
        ti_avg = r.ti_avg&.to_f&.round(1)
        real_pct = r.real_pct&.to_f&.round(1)
        {
          login: channel.login,
          display_name: channel.display_name,
          url: "https://twitch.tv/#{channel.login}",
          real_avg_viewers: real_avg,
          shown_avg_viewers: shown_avg,
          real_pct: real_pct,
          # single source of truth: derive from the SQL real_pct (not the rounded avgs) so
          # real_pct + |bot_correction_pct| == 100 exactly (CR nit).
          bot_correction_pct: real_pct && shown_avg.positive? ? -(100 - real_pct).round(1) : nil,
          classification: classifications[r.channel_id],
          # PR3b: label from the persisted band when present (5-color, legal-safe i18n); the
          # ErvCalculator TI-scale resolver serves only pre-cutover rows.
          classification_label: classification_label_for(r.channel_id, ti_avg),
          category: stream&.game_name,
          language: stream&.language,
          streams_per_week: r.spw&.to_f&.round(1),
          ti_avg: ti_avg
        }
      end
    end

    def latest_streams_by_channel(ids)
      Stream.where(channel_id: ids)
            .select("DISTINCT ON (channel_id) channel_id, game_name, language, started_at")
            .order("channel_id, started_at DESC")
            .index_by(&:channel_id)
    end

    # Bounded to the page's channel_ids (not the whole population).
    def latest_classification_by_channel(ids)
      @latest_bands = {}
      TrendsDailyAggregate.where(date: window, channel_id: ids)
                          .select("DISTINCT ON (channel_id) channel_id, classification_at_end, band_row_at_end, band_color_at_end")
                          .order("channel_id, date DESC")
                          .each_with_object({}) do |r, h|
                            h[r.channel_id] = r.classification_at_end
                            @latest_bands[r.channel_id] = r[:band_row_at_end]
                          end
    end

    def classification_label_for(channel_id, ti_avg)
      band_row = @latest_bands&.[](channel_id)
      if band_row
        I18n.t(TrustIndex::V2::BandClassifier.label_key_for(band_row), locale: :ru, default: nil)
      elsif ti_avg
        TrustIndex::ErvCalculator.resolve_label(ti_avg)[:ru]
      end
    end
  end
end
