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

    # ADR DEC-2 (amended BUG-band-unstable 2026-06-25): the band's anomaly component counts ONLY
    # high-confidence bot-identity events — a WHITELIST, not a blacklist. Prod data (recrent ti=98,
    # melharucos ti=83) showed honest channels carry hundreds of statistical CCV-shape detector fires
    # (ccv_step_function/ccv_tier_clustering) + routine TI-signal anomalies (erv_divergence/ti_drop/
    # auth_ratio/...) — all already reflected in the TI mean — but ZERO genuine bot events. The old
    # blacklist ("everything except 3 benign is severe") counted that noise as severe → every channel
    # was "unstable". A whitelist is the safe default: a new anomaly type is NOT severe until added.
    SEVERE_ANOMALY_TYPES = %w[
      viewbot_spike anomaly_wave follow_bot raid_bot chat_bot known_bot_match account_profile_scoring
    ].freeze

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

    # T1-065 DEC-2: pure band cascade — the SINGLE source of truth for the descriptor, reused by
    # Reputation::HistoryService to derive the per-point rolling-window band trajectory. Caller
    # supplies `scores` (>= 2 final TI snapshots) + `severe_rate` (severe anomalies / window size).
    # Identical cascade to the instance path → /trust, /reputation/history and the trajectory all
    # classify from one place (thresholds can't drift). Assumes scores.size >= 2 (callers gate).
    def self.classify(scores, severe_rate)
      mean = scores.sum / scores.size
      std = Math.sqrt(scores.sum { |s| (s - mean)**2 } / scores.size)

      return "unstable"   if mean < UNSTABLE_TI || severe_rate > UNSTABLE_RATE
      return "impeccable" if mean >= IMPECCABLE_TI && std <= IMPECCABLE_STD && severe_rate.zero?
      return "stable"     if mean >= STABLE_TI && std <= STABLE_STD && severe_rate <= STABLE_RATE

      "variable"
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
    # T1-065 DEC-2: delegates to the pure class-method classify (single source) with this window's
    # severe_anomaly_rate — instance behaviour is unchanged (T1-064 band_service_spec stays green).
    def derive_band(scores)
      self.class.classify(scores, severe_anomaly_rate)
    end

    # ADR DEC-3: final trust snapshot per completed stream (settled value), last 30 sessions.
    # PR3b (T1-074): per-row engine discrimination — each stream's FINAL row is the authoritative
    # output of whichever engine wrote it: v2 rows contribute `authenticity` (0-100, A=100·(1−F̂/V)),
    # v1 rows contribute `trust_index_score` (same scale). This keeps the 30-stream rolling window
    # populated across the cutover (a strict v2-only filter would empty every band for weeks) while
    # never reading `authenticity` off a v1 row or `trust_index_score` off a v2 row (iron rule,
    # satisfied per-row). Flag-free: data-driven, correct with ti_v2_engine OFF, ON, or flapped.
    def window_ti_scores
      ids = window_stream_ids
      return [] if ids.empty?

      TrustIndexHistory
        .where(stream_id: ids)
        .select(<<~SQL.squish)
          DISTINCT ON (stream_id) stream_id, engine_version,
          CASE WHEN engine_version = 'v2' THEN authenticity ELSE trust_index_score END AS window_score
        SQL
        .order(Arel.sql("stream_id, calculated_at DESC"))
        .filter_map { |t| t[:window_score]&.to_f }
    end

    def window_stream_ids
      @window_stream_ids ||=
        @channel.streams.where.not(ended_at: nil).order(ended_at: :desc).limit(WINDOW).pluck(:id)
    end

    # Fraction of window streams that carried at least one genuine bot-identity event (∈ [0, 1]).
    # BUG-band-unstable (2026-06-25): count DISTINCT streams, not raw anomaly rows. The detectors
    # fire many rows per stream (recrent: 323 rows over 11 streams), so raw rows / streams gave a
    # rate of ~29 — meaningless against the 0.34 threshold, which expects "share of streams with a
    # severe issue". Denominator = all completed streams in the window (a stream missing a TIH still
    # counts as an observed session, consistent with mean/stddev being over TIH'd streams only).
    def severe_anomaly_rate
      ids = window_stream_ids
      return 0.0 if ids.empty?

      streams_with_severe = Anomaly
        .where(stream_id: ids, anomaly_type: SEVERE_ANOMALY_TYPES)
        .distinct.count(:stream_id)
      streams_with_severe.to_f / ids.size
    end
  end
end
