# frozen_string_literal: true

# TASK-028 FR-006: Channel Protection Score (CPS) signal.
# CPS 0-100 from 7 channel settings. Low CPS = vulnerable to bots.
#
# Phase 4 J calibration (2026-06-03): CPS measures the CHANNEL OWNER's protective
# settings (follower-only mode / sub-only mode / slow mode / emote-only / verified-account
# requirement), NOT chatter behavior. An honest streamer who keeps chat open trades
# protection for accessibility — they are not at fault for the openness, and the
# audience reality (real viewers vs bots) is captured by the other 7 signals
# (auth_ratio / chat_behavior / known_bot_match / raid_attribution / chatter_ccv_ratio
# / cross_channel_presence / account_profile_scoring).
#
# Pre-Phase-4-J behavior penalized open channels linearly: `value = 1.0 - CPS/100`,
# so a CPS=20 channel contributed `0.8 * weight ≈ 5.6%` TI drag. That dragged honest
# big-streamer scores (Recrent: 6482 ccv, blueMark partner) from a deserved ~100 down to
# 87 — surfaced via [[feedback-verify-on-live-streamer-strict-enforcement]] strict-verify
# violation incident 2026-06-02.
#
# Post-Phase-4-J semantics:
#   - CPS ≥ CPS_NEUTRAL_THRESHOLD (30) → value = 0.0 (neutral; protection is the streamer's
#     choice, not a bot indicator). Above-threshold protection is good but does not earn
#     additional credit vs the baseline.
#   - CPS < 30 → linear penalty up to MAX_VALUE_AT_ZERO_CPS (0.3) at CPS=0. Even a fully
#     unprotected channel contributes ≤0.3 × weight 0.07 = ~2.1% TI penalty — significant
#     only when the channel is in the "anyone can chat without verification" tier where a
#     bot raid would meet zero friction.
#
# Per [[feedback-no-throwaway-go-to-final-architecture]] the signal is retained (it still
# measures real risk exposure) — only the directionality + magnitude is fixed.

module TrustIndex
  module Signals
    class ChannelProtectionScore < BaseSignal
      def name = "Channel Protection Score"
      def signal_type = "channel_protection_score"

      # Threshold above which the signal contributes nothing. Tied to the cps_breakdown
      # — 30 ≈ "follower-only any-duration alone" or "subscriber-only + slow-mode", i.e.
      # the minimum bar a serious channel runs. Below this = chat is effectively open.
      CPS_NEUTRAL_THRESHOLD = 30
      # Max signal value at CPS=0 (fully open). 0.3 × normalized weight ≈0.07 (seed 0.05
      # renormalized across 11 available signals in Engine#compute_raw_ti) ≈ 2.1% TI
      # penalty — small enough to never drive an honest open-chat streamer below
      # "trusted" tier on its own; large enough to surface in audit when paired with
      # other suspicious signals.
      MAX_VALUE_AT_ZERO_CPS = 0.3

      def calculate(context)
        config = context[:channel_protection_config]

        # No config = no signal contribution. Pre-Phase-4-J this returned value=1.0 with
        # confidence=0.0; the confidence-zero guard in Engine#compute_raw_ti drops it from
        # the available signals so the bot_score was unaffected — but a value=1.0 emitted
        # on a no-data branch is a footgun (any future refactor that surfaces low-confidence
        # signals would suddenly apply a max-penalty no-config row to every fresh channel).
        return result(value: 0.0, confidence: 0.0, metadata: { reason: "no_config" }) unless config

        cps = compute_cps(config)

        value = if cps >= CPS_NEUTRAL_THRESHOLD
                  0.0
        else
                  ((CPS_NEUTRAL_THRESHOLD - cps).to_f / 100.0).clamp(0.0, MAX_VALUE_AT_ZERO_CPS)
        end

        freshness = config.respond_to?(:last_checked_at) && config.last_checked_at
        confidence = freshness && freshness > 1.hour.ago ? 1.0 : 0.5

        result(
          value: value,
          confidence: confidence,
          metadata: { cps: cps, components: cps_breakdown(config) }
        )
      end

      private

      # BUG-251.32: recalibrated CPS components matching the post-schema-shift fields Twitch
      # actually exposes today (chatSettings.requireVerifiedAccount replaces the removed
      # email/phone/min-age/restrict-first-timer subtype). Legacy boolean columns
      # (email_verification_required / phone_verification_required / minimum_account_age_minutes /
      # restrict_first_time_chatters) still readable on historical rows for back-compat but no
      # longer drive new CPS scoring — they always read as defaults (false / 0) for new rows.
      #
      # Weights re-anchored to total 100:
      #   follower-only mode:        0/15/30
      #   subscriber-only mode:      20
      #   slow mode:                 0/5/10/15
      #   emote-only mode:           5
      #   verified_account_required: 30
      #   ───────────────────────────
      #   max                       100
      def compute_cps(config)
        score = 0

        # Verified-account required (chatSettings.requireVerifiedAccount, 30 pts)
        score += 30 if config.verified_account_required

        # Follower-only mode (0/15/30 pts) — duration_min nil = no FO; 0 = FO any duration;
        # any positive = stricter FO window
        fol = config.followers_only_duration_min
        score += if fol.nil? || fol < 0
                   0
        elsif fol == 0
                   15
        else
                   30
        end

        # Subscriber-only mode (20 pts)
        score += 20 if config.subs_only_enabled

        # Slow mode (0/5/10/15 pts)
        slow = config.slow_mode_seconds || 0
        score += if slow <= 0
                   0
        elsif slow <= 10
                   5
        elsif slow <= 30
                   10
        else
                   15
        end

        # Emote-only mode (5 pts)
        score += 5 if config.emote_only_enabled

        [ score, 100 ].min
      end

      def cps_breakdown(config)
        {
          verified_account_required: config.verified_account_required,
          followers_only: config.followers_only_duration_min,
          subs_only: config.subs_only_enabled,
          slow_mode: config.slow_mode_seconds,
          emote_only: config.emote_only_enabled
        }
      end
    end
  end
end
