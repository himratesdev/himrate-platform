# frozen_string_literal: true

# TASK-028 FR-001 + BUG-251.30: Auth Ratio signal #1.
#
# Compute: (chatters_present_total / latest_ccv) — share of registered users actually
# present in chat (broadcasters + moderators + vips + staff + viewers from CommunityTab)
# divided by total concurrent viewer count.
#
# Concept: viewbots that ONLY connect to the video stream (skip IRC entirely) depress this
# ratio. Genuine human viewers either join chat to read messages OR aren't logged in (which
# is fine — anonymous viewers naturally absent from chatters list).
#
# Source: `app/services/trust_index/context_builder.rb` injects `:chatters_present_total`
# from the latest `ChattersSnapshot.chatters_present_total` (populated every 60s by
# `StreamMonitorWorker#poll_tier1` via `Twitch::GqlClient#community_tab`).
#
# Distinct from Signal #2 (chatter_ccv_ratio):
#   - #1 (this signal): PRESENCE in chat (whether they typed or not) / CCV
#   - #2: ACTIVE TYPERS (people who sent privmsg) / CCV
# Two views catch different bot classes: video-only viewbots fail #1; chat-quiet-viewbots
# also fail #2; clean silent audiences (Dota/CS/Chess) pass both at calibrated thresholds.
#
# History:
#   - TASK-251.6: signal abstained server-side because CommunityTab was integrity-gated
#     under web Client-ID `kimne78kx3ncx6brgo4mv6wki5h1ko`.
#   - TASK-251.9: KEEP decision (distinct from #2 — present-vs-silent class of bot).
#   - BUG-251.30 (2026-05-29): Wave-3 Android Client-ID `kd1unb4b3q4t58fwlpcbzcbnm76a8fp`
#     bypasses Kasada integrity → CommunityTab works server-side. Abstain removed.
#     ChattersPresenceSnapshot semantics reflected in conservative recalibrated thresholds
#     (paired migration `20260529110002_recalibrate_auth_ratio_...`).
#     Multi-channel empirical recalibration tracked under BUG-251.33.
#
# Zero-vs-nil philosophy (Option A per `_tasks/BUG-TI-CALIBRATION-SMALL-STREAMERS/
# auth-ratio-philosophy-decision.md`, 2026-06-04): the `chatters_present.nil?` guard
# at line 48 fires ONLY on missing data, NOT on zero. When `chatters_present_total = 0`
# with `ccv > 0`, the signal intentionally PROCEEDS to ratio math → value = 1.0
# (MAX bot). Rationale: viewbots that ONLY join the video stream (skip IRC entirely)
# depress chatters_present to literal zero; a legitimate stream nearly always has
# *some* presence — broadcaster + mods + a few viewers — in the 60s polling window.
# Source `ChattersSnapshot.chatters_present_total` is populated by BSW (Twitch GQL
# CommunityTab) with high reliability post-PR #221+#223 (Android Client-ID + Tier-2
# stability), so zero is a strong signal not an ingest gap. **Contrast with sibling
# signal `chatter_ccv_ratio` (PR #276, Phase 4 J PR-E):** that signal DOES abstain on
# `unique_chatters_60min = 0` because its source (CH `mv_stream_minute_target` ←
# IRC monitor) has known capacity issues (MAX_CHANNELS cap, late-subscribe) where
# zero often means "ingest gap" rather than "no humans". Both philosophies are
# locally correct per their data-source reliability profile. If BSW reliability ever
# degrades (or IRC capacity ever improves) we re-audit and may flip per-source.

module TrustIndex
  module Signals
    class AuthRatio < BaseSignal
      DEFAULT_EXPECTED_MIN = 0.03

      def name = "Auth Ratio"
      def signal_type = "auth_ratio"

      def calculate(context)
        ccv = context[:latest_ccv]
        chatters_present = context[:chatters_present_total]
        category = context[:category] || "default"
        stream_duration_min = context[:stream_duration_min] || 0

        return insufficient(reason: "no_ccv") unless ccv&.positive?
        return insufficient(reason: "no_chatters_present_data") if chatters_present.nil?

        ratio = chatters_present.to_f / ccv
        params = config_params(category)
        expected_min = params["expected_min"]&.to_f || DEFAULT_EXPECTED_MIN

        # Continuous score: ratio >= expected_min → 0.0 (no alert), else linearly scaled
        # to 1.0 when ratio = 0 (all viewers anonymous = max suspicion).
        value = ratio >= expected_min ? 0.0 : (expected_min - ratio) / expected_min

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
            expected_min: expected_min,
            chatters_present: chatters_present,
            ccv: ccv,
            category: category
          }
        )
      end
    end
  end
end
