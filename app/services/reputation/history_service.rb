# frozen_string_literal: true

# T1-065: Reputation history / trajectory — the FREE trust-summary that backs layer 3 of the
# channel card (access-model v2: the card is 100% free to the viewer). Pure derivation over
# existing tables (no schema). One data-load produces, consistently:
#   - current          {band, tier, stream_count}      — Option C (DEC-3): band == rightmost
#                                                         trajectory point, computed in THIS pass
#                                                         (not BandService.cached_for) → no cache race.
#   - trend            {direction, delta_pct}           — DEC-7: recent-half vs older-half ERV%.
#   - real_audience_trajectory [{stream_index, ended_at, ti_score, real_audience_pct, band}]
#                                                         — per-stream, band = rolling-window derive.
#   - components_history [{calculated_at, growth_pattern, follower_quality, engagement_consistency}]
#                                                         — 3 public StreamerReputation components.
#   - follower_quality_stubbed                           — honest flag (compute is a stub upstream).
#
# Band cascade is the SINGLE source Reputation::BandService.classify (DEC-2) → /trust and the
# trajectory can't drift. Cache: read-through 6h + invalidate at stream-end (DEC-4).
module Reputation
  class HistoryService
    WINDOW = BandService::WINDOW          # 30 — rolling window + display length
    # Load 2*WINDOW-1 completed streams so the OLDEST displayed point still has a full trailing-30
    # sub-window where data exists; display the most recent WINDOW.
    LOAD_LIMIT = (2 * WINDOW) - 1         # 59
    # DEC-7: |Δ ERV%| beyond this between recent-half and older-half flips improving/declining.
    TREND_THRESHOLD = 5.0
    MIN_TREND_POINTS = 4                  # need >= 2 non-null points per half
    CACHE_TTL = 6.hours

    def self.cache_key(channel_id)
      "reputation_history_v2:#{channel_id}" # PR3b: bumped — old-shape 6h cache entries must not serve post-deploy
    end

    # Read path (free endpoint). Lazy compute, 6h backstop; invalidated at stream-end (DEC-4).
    def self.cached_for(channel)
      Rails.cache.fetch(cache_key(channel.id), expires_in: CACHE_TTL) { new(channel).call }
    end

    def initialize(channel)
      @channel = channel
    end

    def call
      assessment = TrustIndex::ColdStartGuard.assess(@channel)
      tier = map_tier(assessment[:status])
      stream_count = assessment[:stream_count]

      # EC-1: insufficient (<3 streams) → honest-empty (band null, empty series), HTTP 200.
      return empty_payload(tier, stream_count) if tier == "insufficient"

      ordered = load_window_streams
      ids = ordered.map(&:first)
      tih_by_stream = load_final_tih(ids)
      severe_streams = load_severe_streams(ids)

      trajectory = build_trajectory(ordered, tih_by_stream, severe_streams)

      {
        channel_id: @channel.id,
        channel_login: @channel.login,
        window: WINDOW,
        # Option C (DEC-3): current.band IS the rightmost trajectory point — one computation, so
        # AC-4 (last point == current) is a tautology and the band/trajectory can't disagree.
        current: { band: trajectory.last&.dig(:band), tier: tier, stream_count: stream_count },
        trend: build_trend(trajectory),
        real_audience_trajectory: trajectory,
        components_history: build_components_history,
        follower_quality_stubbed: true
      }
    end

    private

    def empty_payload(tier, stream_count)
      {
        channel_id: @channel.id,
        channel_login: @channel.login,
        window: WINDOW,
        current: { band: nil, tier: tier, stream_count: stream_count },
        trend: { direction: nil, delta_pct: nil },
        real_audience_trajectory: [],
        components_history: [],
        follower_quality_stubbed: true
      }
    end

    # Mirror BandService#map_tier: 5-status ColdStartGuard → 3-tier band enum (FD-4 canon).
    def map_tier(cold_start_status)
      case cold_start_status
      when "insufficient" then "insufficient"
      when "provisional_low", "provisional" then "basic"
      else "full"
      end
    end

    # DEC-2: last 59 completed streams, oldest→newest. [[id, ended_at], ...]. Reuses the
    # idx_streams_ended_at_partial path that BandService#window_stream_ids already uses in prod.
    def load_window_streams
      @channel.streams
              .where.not(ended_at: nil)
              .order(ended_at: :desc)
              .limit(LOAD_LIMIT)
              .pluck(:id, :ended_at)
              .reverse
    end

    # Final TIH per stream (DISTINCT ON), index_by stream_id. Mirrors BandService#window_ti_scores;
    # hits idx_tih_stream_calculated_id (stream_id, calculated_at DESC).
    # PR3b (T1-074): per-row engine discrimination, IDENTICAL to BandService#window_ti_scores
    # (MF-1 coherence — current.band must equal BandService#call). For v2 rows
    # real_audience_pct == authenticity EXACTLY (A = ERV/V·100) — one value serves both.
    def load_final_tih(stream_ids)
      return {} if stream_ids.empty?

      TrustIndexHistory
        .where(stream_id: stream_ids)
        .select(<<~SQL.squish)
          DISTINCT ON (stream_id) stream_id, engine_version,
          CASE WHEN engine_version = 'v2' THEN authenticity ELSE trust_index_score END AS window_score,
          CASE WHEN engine_version = 'v2' THEN authenticity ELSE erv_percent END AS audience_pct
        SQL
        .order(Arel.sql("stream_id, calculated_at DESC"))
        .index_by(&:stream_id)
    end

    # Set of window stream_ids that carried >=1 genuine bot-identity anomaly. Mirrors
    # BandService#severe_anomaly_rate (BUG-band-unstable: whitelist SEVERE_ANOMALY_TYPES + DISTINCT
    # stream, not raw rows). A stream is "severe" or not — its raw anomaly-row count is irrelevant.
    def load_severe_streams(stream_ids)
      return Set.new if stream_ids.empty?

      Anomaly
        .where(stream_id: stream_ids, anomaly_type: BandService::SEVERE_ANOMALY_TYPES)
        .distinct.pluck(:stream_id)
        .to_set
    end

    # DEC-2: display the most recent WINDOW streams; each point's band = derive over its trailing
    # <=WINDOW sub-window via the shared BandService.classify (single source).
    def build_trajectory(ordered, tih_by_stream, severe_streams)
      display_start = [ ordered.size - WINDOW, 0 ].max

      (display_start...ordered.size).map do |i|
        stream_id, ended_at = ordered[i]
        sub = ordered[[ 0, i - WINDOW + 1 ].max..i] # trailing <=30 streams incl. current

        scores = sub.filter_map { |sid, _| tih_by_stream[sid]&.[](:window_score)&.to_f }
        # Fraction of sub streams that had >=1 bot event (∈ [0,1]); denominator = ALL sub streams
        # (TIH-less still an observed session) — mirrors BandService#severe_anomaly_rate.
        severe_rate = sub.count { |sid, _| severe_streams.include?(sid) }.to_f / sub.size
        band = scores.size < 2 ? nil : BandService.classify(scores, severe_rate)

        tih = tih_by_stream[stream_id]
        {
          stream_index: i - display_start,
          ended_at: ended_at.iso8601,
          # PR3b MF-2: DUAL-EMIT during the transition — the SHIPPED extension still reads
          # ti_score (T2 migration branch is unmerged); authenticity = the same value for new
          # clients. Drop ti_score in the post-flip cleanup PR. `band` here = CATEGORICAL
          # reputation band (impeccable/stable/…), NOT the v2 6-row band.
          ti_score: tih&.[](:window_score)&.to_f&.clamp(0.0, 100.0),
          authenticity: tih&.[](:window_score)&.to_f&.clamp(0.0, 100.0),
          real_audience_pct: tih&.[](:audience_pct)&.to_f&.clamp(0.0, 100.0),
          band: band
        }
      end
    end

    # FR-5: 3 PUBLIC components, oldest→newest, last <=30. pattern_history_score is the internal
    # 4th component (BR-3) and is intentionally NOT exposed. Keyed by calculated_at (the table has
    # no stream_id) → a parallel series to real_audience_trajectory, never per-stream joined (BR-9).
    def build_components_history
      StreamerReputation
        .where(channel_id: @channel.id)
        .order(calculated_at: :desc)
        .limit(WINDOW)
        .to_a
        .reverse
        .map do |r|
          {
            calculated_at: r.calculated_at.iso8601,
            growth_pattern: r.growth_pattern_score&.to_f,
            follower_quality: r.follower_quality_score&.to_f,
            engagement_consistency: r.engagement_consistency_score&.to_f
          }
        end
    end

    # FR-8 / DEC-7: directional descriptor from recent-half vs older-half real_audience_pct
    # (ERV% — continuous, finer than the 4-level band). null when < MIN_TREND_POINTS non-null.
    def build_trend(trajectory)
      pcts = trajectory.filter_map { |p| p[:real_audience_pct] }
      return { direction: nil, delta_pct: nil } if pcts.size < MIN_TREND_POINTS

      half = pcts.size / 2
      older = pcts.first(half)
      recent = pcts.last(half)
      delta = ((recent.sum / recent.size) - (older.sum / older.size)).round(1)

      direction =
        if delta > TREND_THRESHOLD then "improving"
        elsif delta < -TREND_THRESHOLD then "declining"
        else "stable"
        end

      { direction: direction, delta_pct: delta }
    end
  end
end
