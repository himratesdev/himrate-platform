# frozen_string_literal: true

# T1-064 FR-3: Reputation Categorical band — Безупречная / Стабильная / Изменчивая / Нестабильная
# (EN: Impeccable / Stable / Variable / Unstable). Canonical descriptor that replaced the
# removed philosophy-v2 Health Score.
#
# Canon (bft/platform/43_Glossary.md): derived from the TI Rolling Window (30 stream sessions)
# + anomaly event distribution — NOT from the 3 reputation component scores (those are TI
# signals). "Describes fact, not goal" (Detective-not-Coach). No history timeline → that is
# T1-065 (trajectory) scope.
module Reputation
  class BandService
    WINDOW = 30
    # Eventual consistency (ADR DEC-4): band is computed at stream-end (post_stream_worker) and
    # cached for CACHE_TTL. A late-detected anomaly is intentionally NOT invalidated mid-window —
    # it folds into the band on the next stream-end or on TTL expiry. This avoids per-anomaly
    # recompute churn; band is a window-level descriptor, not a real-time signal.
    CACHE_TTL = 6.hours

    # ADR DEC-2: benign (organic_spike/host_raid) + system (compute_failure) anomaly types
    # do NOT penalize the band. Everything else counts as severe (safe default for new types).
    BENIGN_OR_EXCLUDED = %w[organic_spike host_raid compute_failure].freeze

    # ADR DEC-1: band thresholds (tunable constants — deterministic derivation, no Flipper).
    IMPECCABLE_TI = 85.0
    STABLE_TI = 70.0
    UNSTABLE_TI = 50.0
    IMPECCABLE_STD = 8.0
    STABLE_STD = 15.0
    STABLE_RATE = 0.1
    UNSTABLE_RATE = 0.34

    def self.cache_key(channel_id)
      "reputation_band:#{channel_id}"
    end

    # Read path (card / trust full view): cache hit or lazy compute.
    def self.cached_for(channel)
      Rails.cache.fetch(cache_key(channel.id), expires_in: CACHE_TTL) { new(channel).call }
    end

    # Write path (post_stream_worker): recompute + warm cache after stream finalization.
    def self.refresh(channel)
      result = new(channel).call
      Rails.cache.write(cache_key(channel.id), result, expires_in: CACHE_TTL)
      result
    end

    def initialize(channel)
      @channel = channel
    end

    # => { band:, tier:, stream_count: }. tier ∈ {insufficient | basic | full} (FD-4 canon, 3 tiers).
    # band=nil ONLY at insufficient (<3 streams) — explicit tier instead of a bare nil. For `basic`
    # (3-9 streams) the frontend shows a "Provisional — N streams" tooltip derived from stream_count.
    def call
      assessment = TrustIndex::ColdStartGuard.assess(@channel)
      tier = map_tier(assessment[:status])
      count = assessment[:stream_count]
      return descriptor(nil, tier, count) if tier == "insufficient"

      scores = window_ti_scores
      return descriptor(nil, tier, count) if scores.size < 2

      descriptor(derive_band(scores), tier, count)
    end

    private

    # FD-4 (Glossary "Cold-start", 3 tiers): project the 5-status TI ColdStartGuard onto the
    # 3-tier reputation band enum. ColdStartGuard (TI cold-start) intentionally stays 5-status —
    # only the band descriptor exposes the simplified 3-tier (insufficient / basic / full).
    def map_tier(cold_start_status)
      case cold_start_status
      when "insufficient" then "insufficient"               # <3 streams → band hidden
      when "provisional_low", "provisional" then "basic"    # 3-9 streams → "Provisional — N streams"
      else "full"                                           # full (≥10) / deep (≥30)
      end
    end

    def descriptor(band, tier, stream_count)
      { band: band, tier: tier, stream_count: stream_count }
    end

    # ADR DEC-1 cascade (worst-first): level (mean_ti) + stability (stddev) + anomalies (rate).
    def derive_band(scores)
      mean = scores.sum / scores.size
      std = Math.sqrt(scores.sum { |s| (s - mean)**2 } / scores.size)
      rate = severe_anomaly_rate

      return "unstable"   if mean < UNSTABLE_TI || rate > UNSTABLE_RATE
      return "impeccable" if mean >= IMPECCABLE_TI && std <= IMPECCABLE_STD && rate.zero?
      return "stable"     if mean >= STABLE_TI && std <= STABLE_STD && rate <= STABLE_RATE

      "variable"
    end

    # ADR DEC-3: final TI snapshot per completed stream (settled value), last 30 sessions.
    def window_ti_scores
      ids = window_stream_ids
      return [] if ids.empty?

      TrustIndexHistory
        .where(stream_id: ids)
        .select("DISTINCT ON (stream_id) stream_id, trust_index_score")
        .order(Arel.sql("stream_id, calculated_at DESC"))
        .filter_map { |t| t.trust_index_score&.to_f }
    end

    def window_stream_ids
      @window_stream_ids ||=
        @channel.streams.where.not(ended_at: nil).order(ended_at: :desc).limit(WINDOW).pluck(:id)
    end

    # severe anomalies per stream across the window. Denominator = all completed streams in the
    # window (window_stream_ids), NOT just streams that have a TIH: anomalies are counted per
    # session, so a stream missing a TIH snapshot still counts as an observed session. This means
    # the rate can be slightly diluted vs mean/stddev (computed only over streams with a TIH) —
    # intentional, "severe events per session" is the meaningful unit.
    def severe_anomaly_rate
      ids = window_stream_ids
      return 0.0 if ids.empty?

      severe = Anomaly.where(stream_id: ids).where.not(anomaly_type: BENIGN_OR_EXCLUDED).count
      severe.to_f / ids.size
    end
  end
end
