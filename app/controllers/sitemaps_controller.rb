# frozen_string_literal: true

# XML sitemap of the indexable marketing pages. The Pencil-export nav is JS-driven
# (no crawlable <a href>), so the sitemap is the authoritative discovery channel for
# Google. LK app shells (/app/*), /login and API routes are intentionally excluded
# (noindex + robots Disallow). Public and unauthenticated. (TASK-060 SEO)
class SitemapsController < ApplicationController
  # Indexable marketing + legal paths, relative to the canonical apex host. The legal
  # pages (/privacy, /terms) are self-canonical and required for the Chrome Web Store
  # listing (privacy-policy URL); the marketing nav does not link them, so the sitemap
  # is their only discovery channel. /support is listed on the same footing; its twin
  # /feedback is the SAME page and canonicalizes to /support, so it is deliberately absent.
  PATHS = %w[/ /streamers /brands /viewers /methodology /privacy /terms /support].freeze

  # EPIC-64: the long-deferred «curated real-data set» gate for /c/:login entries — a
  # channel earns a sitemap slot with ≥ MIN_STREAMS tracked streams over the 30-day
  # window AND a present band verdict on its latest aggregate (cold-start ≥ basic).
  # Every other login stays reachable-but-unlisted, exactly as before. Capped + cached
  # daily — the sitemap needs nightly freshness (SA-12 AC), not per-request recompute.
  CHANNELS_MIN_STREAMS = 10
  CHANNELS_CAP = 500
  # v2: entries carry [path, lastmod-date] — <lastmod> tells Google WHICH pages changed, so the
  # crawl budget goes to fresh channel cards instead of even re-sweeps (GSC showed a long
  # «discovered, not indexed» tail; lastmod is the standard prioritization signal for it).
  CHANNELS_CACHE_KEY = "sitemap:channel_paths:v2"
  CHANNELS_CACHE_TTL = 24.hours

  def show
    channel_entries = channel_paths
    data_lastmod = channel_entries.filter_map(&:last).max
    entries = PATHS.map { |p| [ p, nil ] } +
              top_paths.map { |p| [ p, data_lastmod ] } +
              channel_entries
    @urls = entries.map { |path, lastmod| [ "#{ApplicationHelper::CANONICAL_HOST}#{path}", lastmod ] }
    render layout: false, formats: :xml
  end

  private

  # /top + one page per qualifying category (quality-gated + cached in the registry).
  def top_paths
    tops = PublicTop::Categories.all.map { |c| "/top/#{c[:slug]}" }
    tops.empty? ? [] : [ "/top" ] + tops
  end

  # → [[path, lastmod-date]]: lastmod = the channel's latest in-window aggregate date (the day
  # its public card content last materially changed).
  def channel_paths
    Rails.cache.fetch(CHANNELS_CACHE_KEY, expires_in: CHANNELS_CACHE_TTL) do
      window = PublicTop::Categories::WINDOW_DAYS.days.ago.to_date..Date.current
      active_ids = TrendsDailyAggregate.where(date: window).group(:channel_id)
                                       .having("SUM(streams_count) >= ?", CHANNELS_MIN_STREAMS)
                                       .pluck(:channel_id)
      next [] if active_ids.empty?

      banded = TrendsDailyAggregate
               .from(
                 TrendsDailyAggregate.where(date: window, channel_id: active_ids)
                                     .select("DISTINCT ON (channel_id) channel_id, date, band_row_at_end")
                                     .order("channel_id, date DESC"), :t
               )
               .where.not(t: { band_row_at_end: nil })
               .limit(CHANNELS_CAP)
               .pluck("t.channel_id", "t.date").to_h
      Channel.where(id: banded.keys).order(:login).pluck(:login, :id)
             .map { |login, id| [ "/c/#{login}", banded[id] ] }
    end
  end

  # Crawlers may be old — never 406 the sitemap on the modern-browser guard.
  def browser_guard_enabled?
    false
  end
end
