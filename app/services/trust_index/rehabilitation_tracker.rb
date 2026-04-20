# frozen_string_literal: true

# TASK-038 FR-028 / AR-11: Rehabilitation state tracker.
# Reads from explicit rehabilitation_penalty_events table (not derived).
# Returns { active:, clean_streams:, required:, progress_pct: }.

module TrustIndex
  class RehabilitationTracker
    # TASK-039 FR-047: SignalConfiguration acceleration_factor (default 0.2 → 20%
    # max boost from full bonus). Build-for-years — admin tunable, не hardcoded.
    SIGNAL_TYPE = "trust_index"
    CONFIG_CATEGORY = "rehabilitation_bonus"

    def self.call(channel)
      active_event = RehabilitationPenaltyEvent.latest_active_for(channel.id)
      return { active: false } unless active_event

      clean_streams = count_clean_streams_since(channel, active_event.applied_at)
      required = active_event.required_clean_streams
      progress_pct = ((clean_streams.to_f / required) * 100).round.clamp(0, 100)

      # TASK-039 FR-046/047: bonus accelerator extension. Bonus computed via
      # stored snapshot percentiles в TIH (Phase A3a foundation).
      bonus = BonusAcceleratorCalculator.call(channel, active_event)
      effective_progress_pct = compute_effective_progress(clean_streams, required, bonus)

      {
        active: true,
        clean_streams: clean_streams,
        required: required,
        progress_pct: progress_pct,
        effective_progress_pct: effective_progress_pct,
        applied_at: active_event.applied_at.iso8601,
        initial_penalty: active_event.initial_penalty.to_f,
        bonus: bonus
      }
    end

    # FR-047: effective_clean = clean_streams + (bonus_pts_earned / bonus_max) × required × acceleration_factor
    # progress_pct (raw) preserved для backwards compat — this is parallel field.
    def self.compute_effective_progress(clean_streams, required, bonus)
      bonus_max = bonus[:bonus_pts_max].to_f
      return 0 if bonus_max.zero? || required.zero?

      acceleration_factor = SignalConfiguration.value_for(
        SIGNAL_TYPE, CONFIG_CATEGORY, "rehab_bonus_acceleration_factor"
      ).to_f

      bonus_ratio = bonus[:bonus_pts_earned].to_f / bonus_max
      effective_clean = clean_streams + (bonus_ratio * required * acceleration_factor)

      ((effective_clean / required) * 100).round.clamp(0, 100)
    end

    # M6 fix: filter by stream.started_at > applied_at (not TI.calculated_at).
    # Otherwise, post-penalty TI re-computations of pre-penalty streams
    # (e.g. after backfill/reprocess) would count as "clean streams".
    def self.count_clean_streams_since(channel, since)
      clean_stream_ids = Stream
        .where(channel_id: channel.id)
        .where("started_at > ?", since)
        .pluck(:id)

      return 0 if clean_stream_ids.empty?

      TrustIndexHistory
        .where(channel_id: channel.id, stream_id: clean_stream_ids)
        .where("trust_index_score >= ?", 50)
        .distinct
        .count(:stream_id)
    end
  end
end
