# frozen_string_literal: true

# TASK-028 FR-002: Chatter-to-CCV Ratio signal.
# Unique IRC chatters (60min) / CCV. Category-adjusted.
#
# Phase 4 J PR-B calibration (2026-06-03): the prior implementation used a
# category-based baseline (chatter_ccv_ratio/gaming/expected_ratio_min etc.) but
# falls back to a hardcoded `0.10` when params lookup misses. On staging that
# fallback fires routinely for big channels — zackrawrr (45k ccv, gaming), jynxzi
# (62k ccv, gaming), hasanabi (32k ccv, IRL) — because the category-resolution
# path doesn't always land on a seeded row. With baseline 0.10 the signal
# penalizes any stream where unique_chatters_60min/ccv falls below 10%, which is
# the NORMAL state for big audiences (10× higher ccv ≠ 10× more chatters; lurker
# fraction grows with channel size). Combined with weight 0.14, the misfire
# contributes a 5-14% TI drag across the entire honest-big-streamer population
# (median TI=77 observed across 20 live streams 2026-06-02 post-PR-#264).
#
# CCV-aware baseline scaling: the category baseline is the floor expectation
# tuned for typical-sized streams in that vertical. As CCV grows, the realistic
# minimum chatter ratio shrinks (the lurker tail dominates). The effective
# baseline scales with CCV via a smooth shrink: `base * (CCV_REFERENCE / max(ccv,
# CCV_REFERENCE)).clamp(MIN_SHRINK, 1.0)`. For ccv ≤ CCV_REFERENCE (1000) the
# scale factor is 1.0 (small-channel sensitivity preserved). For ccv ≥
# CCV_REFERENCE/MIN_SHRINK (~3333), the scale factor is the floor MIN_SHRINK
# (0.3). Resulting expected_min for a gaming big channel: 0.040 × 0.3 = 0.012.
# Big-stream chatter ratio of e.g. 0.02 (2%, typical for 30k ccv stream) is now
# above threshold → value=0.
#
# Robust fallback: when `params_for` returns no `expected_ratio_min` row (e.g.
# category not yet seeded, or fresh-clone state before db:seed runs), abstain
# rather than falling through to the prior hardcoded `0.10`. The Engine's
# `confidence>0` filter then drops the signal cleanly. Eliminates the silent
# baseline-misfire that produced the median TI=77 floor on honest big streams.
#
# Phase 4 J PR-E calibration (2026-06-03 BUG-TI-CALIBRATION-SMALL-STREAMERS):
# previously the `unless unique_chatters_60min` abstain check only fired on nil
# (CH query failure). When CH returned an explicit zero — e.g. IRC never joined
# this channel (capacity full / late subscription / monitor restart), or
# `mv_stream_minute_target` MV still backfilling, or chat_messages rows missing
# during the 60-min window — the signal proceeded to `ratio = 0 / ccv = 0` and
# produced value=1.0 (MAX bot). Live probe 2026-06-03 caught three honest small
# RU streamers (kepa_mita ccv=569 → TI=76, ckaiba9 ccv=425 → TI=72,
# restoratorgame ccv=205 → TI=83) where chatter_ccv_ratio contributed full bot
# weight, all because unique_chatters_60min returned 0 (not nil). Doc:
# `_tasks/BUG-TI-CALIBRATION-SMALL-STREAMERS/CONTEXT.md`. Fix: abstain when
# `unique_chatters_60min` is nil OR zero. The cost of false-abstain (signal
# gives no info when chat truly empty for 60min) is acceptable — other signals
# (auth_ratio, account_profile_scoring, raid_attribution) cover the "no humans
# = bots" case more reliably, and silent 60-min chat with active ccv is more
# often an ingest gap than a bot-only audience. Distinguishes "no signal data"
# (abstain) from "low signal data" (penalize via ratio formula). Engine
# `confidence>0` filter drops the abstain cleanly.

module TrustIndex
  module Signals
    class ChatterCcvRatio < BaseSignal
      def name = "Chatter-to-CCV Ratio"
      def signal_type = "chatter_ccv_ratio"

      # CCV at which the baseline starts shrinking. Below this, the configured
      # category baseline (e.g. gaming=0.040) is used as-is. Tied to "small
      # streamer" reference (1k ccv ≈ small-but-monetizable channel).
      CCV_REFERENCE = 1000.0
      # Minimum scale factor applied at very high CCV. 0.3 means a 10k-ccv
      # channel sees baseline × 0.3 (e.g. gaming 0.040 → 0.012). Calibrated so
      # honest big-channel chatter ratios (0.02-0.04 range observed live) clear
      # threshold cleanly.
      MIN_SHRINK = 0.3

      def calculate(context)
        ccv = context[:latest_ccv]
        unique_chatters_60min = context[:unique_chatters_60min]
        category = context[:category] || "default"
        stream_duration_min = context[:stream_duration_min] || 0

        return insufficient(reason: "no_ccv") unless ccv&.positive?
        # Phase 4 J PR-E (2026-06-03): abstain on nil OR zero — see class
        # docstring for the small-streamer ingest-gap incident that motivates
        # this. `&.positive?` short-circuits on nil and excludes 0 / negative.
        return insufficient(reason: "no_irc_data") unless unique_chatters_60min&.positive?

        params = config_params(category)
        base_expected_min = params["expected_ratio_min"]&.to_f
        # Phase 4 J PR-B: abstain when no baseline is configured rather than
        # falling through to the prior hardcoded 0.10. The Engine's
        # confidence>0 filter drops the signal cleanly. See class docstring.
        return insufficient(reason: "no_baseline_config") unless base_expected_min&.positive?

        ratio = unique_chatters_60min.to_f / ccv
        shrink = (CCV_REFERENCE / [ ccv.to_f, CCV_REFERENCE ].max).clamp(MIN_SHRINK, 1.0)
        expected_min = base_expected_min * shrink

        value = if ratio >= expected_min
                  0.0
        else
                  (expected_min - ratio) / expected_min
        end

        confidence = if stream_duration_min >= 30 && ccv >= 50
                       1.0
        elsif stream_duration_min >= 10
                       0.5
        else
                       0.2
        end

        result(
          value: value,
          confidence: confidence,
          metadata: {
            ratio: ratio.round(4),
            base_expected_min: base_expected_min,
            shrink: shrink.round(3),
            expected_min: expected_min.round(4),
            unique_chatters: unique_chatters_60min,
            ccv: ccv
          }
        )
      end
    end
  end
end
