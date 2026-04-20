# frozen_string_literal: true

# TASK-039 Phase A3b (FR-046): Bonus accelerator для rehabilitation progress.
#
# Iterates post-penalty clean streams (TI ≥ threshold, started_at > applied_at), reads
# stored snapshot percentiles из trust_index_history.*_at_end (Phase A3a foundation),
# counts qualifying streams (оба percentile ≥ threshold), returns bonus_pts_earned.
#
# All thresholds в SignalConfiguration (build-for-years — admin tunable):
#   - rehab_bonus_pts_max=15 (cap)
#   - rehab_bonus_per_qualifying_stream=1
#   - rehab_bonus_percentile_threshold=80
#   - clean_stream_ti_threshold=50 (rehabilitation/, shared с RehabilitationTracker — CR N-3)
#
# Source data:
#   - trust_index_histories.engagement_percentile_at_end (Hs::ComponentPercentileService :engagement)
#   - trust_index_histories.engagement_consistency_percentile_at_end (Reputation::ComponentPercentileService :engagement_consistency)
#   - Snapshots populated by Trends::QualifyingPercentileSnapshotWorker post-stream
#   - Backfill rake: trends:backfill_qualifying_percentiles
#
# Edge cases (graceful, no raise):
#   - No active penalty event → caller (RehabilitationTracker) skips bonus computation
#   - No clean streams (post-penalty) → bonus_pts_earned=0, qualifying_signals=nil, no_qualifying message
#   - Clean streams existed но percentiles below threshold → bonus_pts_earned=0, percentile_threshold_below message
#   - Stream без snapshots (race / pre-foundation rows) → не qualifying (skipped в count)
#
# Returns Hash:
# {
#   bonus_pts_earned: Integer,
#   bonus_pts_max: Integer,
#   qualifying_signals: { engagement_percentile: Float, engagement_consistency_percentile: Float } | nil,
#   bonus_description_ru: String,
#   bonus_description_en: String
# }

module TrustIndex
  class BonusAcceleratorCalculator
    SIGNAL_TYPE = "trust_index"
    BONUS_CONFIG_CATEGORY = "rehabilitation_bonus"
    REHAB_CONFIG_CATEGORY = "rehabilitation"

    def self.call(channel, active_event)
      new(channel, active_event).call
    end

    def initialize(channel, active_event)
      @channel = channel
      @active_event = active_event
    end

    def call
      qualifying_records = qualifying_clean_streams
      qualifying_count = qualifying_records.size
      summary = qualifying_signals_summary(qualifying_records)
      bonus_pts_earned = [ pts_max, qualifying_count * per_qualifying ].min

      {
        bonus_pts_earned: bonus_pts_earned,
        bonus_pts_max: pts_max,
        qualifying_signals: summary,
        bonus_description_ru: build_description(:ru, bonus_pts_earned, summary),
        bonus_description_en: build_description(:en, bonus_pts_earned, summary)
      }
    end

    private

    # Post-penalty clean streams с snapshot percentiles passing threshold.
    # Single SQL query через partial index `idx_tih_qualifying_snapshots`.
    def qualifying_clean_streams
      TrustIndexHistory
        .for_channel(@channel.id)
        .joins(:stream)
        .where("streams.started_at > ?", @active_event.applied_at)
        .where("trust_index_score >= ?", clean_ti_threshold)
        .where("engagement_percentile_at_end >= ?", percentile_threshold)
        .where("engagement_consistency_percentile_at_end >= ?", percentile_threshold)
        .pluck(:engagement_percentile_at_end, :engagement_consistency_percentile_at_end)
    end

    # CR N-2: distinguish "никаких clean streams" vs "clean streams но percentiles ниже".
    # Used для finer UX guidance — поможет user understand почему bonus не начислен.
    def any_clean_streams_post_penalty?
      @any_clean_streams_post_penalty ||= TrustIndexHistory
        .for_channel(@channel.id)
        .joins(:stream)
        .where("streams.started_at > ?", @active_event.applied_at)
        .where("trust_index_score >= ?", clean_ti_threshold)
        .exists?
    end

    # Average percentiles across qualifying streams для bonus_description interpolation.
    # nil если zero qualifying (badge скрыт в UI).
    def qualifying_signals_summary(qualifying_records)
      return nil if qualifying_records.empty?

      eng_pcts = qualifying_records.map { |row| row[0].to_f }
      eng_cons_pcts = qualifying_records.map { |row| row[1].to_f }

      {
        engagement_percentile: (eng_pcts.sum / eng_pcts.size).round(1),
        engagement_consistency_percentile: (eng_cons_pcts.sum / eng_cons_pcts.size).round(1)
      }
    end

    # CR N-1: summary computed once в .call, передан как arg вместо повторного compute.
    def build_description(locale, bonus_pts_earned, summary)
      if bonus_pts_earned.positive? && summary
        I18n.t(
          "hs.rehabilitation.bonus.description",
          locale: locale,
          bonus_pts_earned: bonus_pts_earned,
          eng_pct: summary[:engagement_percentile].to_i,
          eng_cons_pct: summary[:engagement_consistency_percentile].to_i
        )
      elsif any_clean_streams_post_penalty?
        # Clean streams existed но percentiles ниже threshold → guidance
        I18n.t("hs.rehabilitation.bonus.percentile_threshold_below", locale: locale)
      else
        # Совсем нет post-penalty clean streams
        I18n.t("hs.rehabilitation.bonus.no_qualifying", locale: locale)
      end
    end

    def pts_max
      @pts_max ||= SignalConfiguration.value_for(SIGNAL_TYPE, BONUS_CONFIG_CATEGORY, "rehab_bonus_pts_max").to_i
    end

    def per_qualifying
      @per_qualifying ||= SignalConfiguration.value_for(SIGNAL_TYPE, BONUS_CONFIG_CATEGORY, "rehab_bonus_per_qualifying_stream").to_i
    end

    def percentile_threshold
      @percentile_threshold ||= SignalConfiguration.value_for(SIGNAL_TYPE, BONUS_CONFIG_CATEGORY, "rehab_bonus_percentile_threshold").to_f
    end

    # CR N-3: shared с RehabilitationTracker для consistent "clean stream" definition.
    def clean_ti_threshold
      @clean_ti_threshold ||= SignalConfiguration.value_for(SIGNAL_TYPE, REHAB_CONFIG_CATEGORY, "clean_stream_ti_threshold").to_f
    end
  end
end
