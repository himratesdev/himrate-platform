# frozen_string_literal: true

module Discover
  # Screen 04 «Куда пойти» — live-now channels ranked by REAL audience (latest TIH ccv × erv%),
  # the same honest metric the public card / brand search use. Viewer-free (any signed-in user,
  # access-model v2). Compute-on-read, no schema:
  #   1. live monitored streams (ended_at IS NULL) → bounded set (only currently-live channels);
  #   2. one DISTINCT ON latest-TIH query for those channels (headline: ccv / erv% / label);
  #   3. rank by real = ccv × erv% in Ruby (live set is small relative to total channels).
  # No recommendations/ML here — the design's «Рекомендации» tab stays deferred until a real
  # rec engine exists.
  class LiveNowQuery
    LIMIT = 24

    def initialize(user:, limit: LIMIT)
      @user = user
      @limit = limit.clamp(1, 50)
    end

    def call
      streams = Stream
                .where(ended_at: nil)
                .joins(:channel).merge(Channel.active.monitored)
                .includes(:channel)
                .order(started_at: :desc)
                .to_a
      # one live stream per channel (defensive — stale unclosed rows shouldn't duplicate a card)
      streams = streams.uniq(&:channel_id)
      return [] if streams.empty?

      ti_by_channel = latest_ti(streams.map(&:channel_id))
      watched = watched_ids

      ranked = streams.map { |stream| build(stream, ti_by_channel[stream.channel_id], watched) }
      ranked.sort_by { |row| -row[:real_viewers].to_i }.first(@limit)
    end

    private

    # Latest TIH per channel — single DISTINCT ON query (same pattern as Watchlists::EnrichmentService).
    def latest_ti(channel_ids)
      TrustIndexHistory
        .where(channel_id: channel_ids)
        .select("DISTINCT ON (channel_id) channel_id, trust_index_score, erv_percent, ccv, calculated_at")
        .order(:channel_id, calculated_at: :desc)
        .index_by(&:channel_id)
    end

    def watched_ids
      @user.tracked_channels.where(tracking_enabled: true).pluck(:channel_id).to_set
    end

    def build(stream, ti, watched)
      channel = stream.channel
      erv = ti&.erv_percent&.to_f
      ccv = ti&.ccv.to_i
      label = erv ? TrustIndex::ErvCalculator.resolve_label(erv) : nil
      {
        login: channel.login,
        display_name: channel.display_name,
        game_name: stream.game_name,
        started_at: stream.started_at&.iso8601,
        is_watched_by_user: watched.include?(channel.id),
        shown_viewers: ccv.positive? ? ccv : nil,
        real_viewers: erv && ccv.positive? ? (ccv * erv / 100.0).round : nil,
        erv_percent: erv&.round(1),
        erv_label: label && label[:ru],
        erv_label_color: label && label[:color],
        ti_score: ti&.trust_index_score&.to_f&.round(1)
      }
    end
  end
end
