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
      "reputation_history:#{channel_id}"
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
      severe_by_stream = load_severe_anomalies(ids)

      trajectory = build_trajectory(ordered, tih_by_stream, severe_by_stream)

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
    def load_final_tih(stream_ids)
      return {} if stream_ids.empty?

      TrustIndexHistory
        .where(stream_id: stream_ids)
        .select("DISTINCT ON (stream_id) stream_id, trust_index_score, erv_percent")
        .order(Arel.sql("stream_id, calculated_at DESC"))
        .index_by(&:stream_id)
    end

    # Severe anomalies per stream (≠ benign/excluded). Mirrors BandService#severe_anomaly_rate.
    # Streams with zero anomalies are simply absent from the hash → callers default to 0.
    def load_severe_anomalies(stream_ids)
      return {} if stream_ids.empty?

      Anomaly
        .where(stream_id: stream_ids)
        .where.not(anomaly_type: BandService::BENIGN_OR_EXCLUDED)
        .group(:stream_id)
        .count
    end

    # DEC-2: display the most recent WINDOW streams; each point's band = derive over its trailing
    # <=WINDOW sub-window via the shared BandService.classify (single source).
    def build_trajectory(ordered, tih_by_stream, severe_by_stream)
      display_start = [ ordered.size - WINDOW, 0 ].max

      (display_start...ordered.size).map do |i|
        stream_id, ended_at = ordered[i]
        sub = ordered[[ 0, i - WINDOW + 1 ].max..i] # trailing <=30 streams incl. current

        scores = sub.filter_map { |sid, _| tih_by_stream[sid]&.trust_index_score&.to_f }
        # Denominator = ALL streams in sub (incl. TIH-less) — mirrors band_service.rb:115-119
        # (severe events per session). `|| 0`: zero-anomaly streams are absent from the hash;
        # without the default `.sum` would raise TypeError on nil (adversarial review, lens A).
        severe_rate = sub.sum { |sid, _| severe_by_stream[sid] || 0 }.to_f / sub.size
        band = scores.size < 2 ? nil : BandService.classify(scores, severe_rate)

        tih = tih_by_stream[stream_id]
        {
          stream_index: i - display_start,
          ended_at: ended_at.iso8601,
          ti_score: tih&.trust_index_score&.to_f,
          real_audience_pct: tih&.erv_percent&.to_f&.clamp(0.0, 100.0),
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
