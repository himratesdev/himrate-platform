# frozen_string_literal: true

# Seed data for development/test (FR-008 → US-003)

user = User.find_or_create_by!(email: "dev@himrate.com") do |u|
  u.username = "dev_user"
  u.role = "viewer"
  u.tier = "free"
end

channel = Channel.find_or_create_by!(twitch_id: "12345678") do |c|
  c.login = "test_streamer"
  c.display_name = "Test Streamer"
  c.broadcaster_type = "partner"
  c.is_monitored = true
end

Stream.find_or_create_by!(channel: channel, started_at: 1.hour.ago) do |s|
  s.title = "Test Stream"
  s.game_name = "Just Chatting"
  s.language = "en"
end

puts "Seed complete: 1 user, 1 channel, 1 stream"

# TASK-028 FR-015: Signal configurations (thresholds + weights from BFT §07.1)
if defined?(SignalConfiguration)
  # rubocop:disable Metrics/BlockLength
  signal_configs = [
    # === Auth Ratio (Signal #1) — BFT §5.1 ===
    # BUG-251.30: recalibrated expected_min for CommunityTab presence semantics (was anchored on
    # chat-widget presence, ~50-100% of CCV; CommunityTab returns narrower subset ~5-15% on
    # organic streams — see paired migration `20260529110002_recalibrate_auth_ratio_...`).
    # Migration + seed kept in sync.
    { signal_type: "auth_ratio", category: "just_chatting", param_name: "expected_min", param_value: 0.050 },
    { signal_type: "auth_ratio", category: "just_chatting", param_name: "expected_max", param_value: 0.90 },
    { signal_type: "auth_ratio", category: "esports", param_name: "expected_min", param_value: 0.010 },
    { signal_type: "auth_ratio", category: "esports", param_name: "expected_max", param_value: 0.74 },
    { signal_type: "auth_ratio", category: "gaming", param_name: "expected_min", param_value: 0.025 },
    { signal_type: "auth_ratio", category: "gaming", param_name: "expected_max", param_value: 0.80 },
    { signal_type: "auth_ratio", category: "irl", param_name: "expected_min", param_value: 0.040 },
    { signal_type: "auth_ratio", category: "irl", param_name: "expected_max", param_value: 0.85 },
    { signal_type: "auth_ratio", category: "music", param_name: "expected_min", param_value: 0.020 },
    { signal_type: "auth_ratio", category: "music", param_name: "expected_max", param_value: 0.78 },
    { signal_type: "auth_ratio", category: "default", param_name: "expected_min", param_value: 0.030 },
    { signal_type: "auth_ratio", category: "default", param_name: "expected_max", param_value: 0.80 },

    # === Chatter-to-CCV Ratio (Signal #2) — BFT §5.2 ===
    # BUG-251.33: expected_ratio_min recalibrated for silent-audience categories (esports
    # Dota/CS/LoL, music, irl) — see paired migration
    # `20260529130001_recalibrate_chatter_ccv_ratio_for_silent_audience_categories`.
    # Migration + seed kept in sync so a fresh `db:seed` after migration is a noop.
    { signal_type: "chatter_ccv_ratio", category: "just_chatting", param_name: "expected_ratio_min", param_value: 0.150 },
    { signal_type: "chatter_ccv_ratio", category: "just_chatting", param_name: "expected_ratio_max", param_value: 0.33 },
    { signal_type: "chatter_ccv_ratio", category: "esports", param_name: "expected_ratio_min", param_value: 0.005 },
    { signal_type: "chatter_ccv_ratio", category: "esports", param_name: "expected_ratio_max", param_value: 0.067 },
    { signal_type: "chatter_ccv_ratio", category: "gaming", param_name: "expected_ratio_min", param_value: 0.040 },
    { signal_type: "chatter_ccv_ratio", category: "gaming", param_name: "expected_ratio_max", param_value: 0.20 },
    { signal_type: "chatter_ccv_ratio", category: "irl", param_name: "expected_ratio_min", param_value: 0.080 },
    { signal_type: "chatter_ccv_ratio", category: "irl", param_name: "expected_ratio_max", param_value: 0.25 },
    { signal_type: "chatter_ccv_ratio", category: "music", param_name: "expected_ratio_min", param_value: 0.030 },
    { signal_type: "chatter_ccv_ratio", category: "music", param_name: "expected_ratio_max", param_value: 0.15 },
    { signal_type: "chatter_ccv_ratio", category: "default", param_name: "expected_ratio_min", param_value: 0.040 },
    { signal_type: "chatter_ccv_ratio", category: "default", param_name: "expected_ratio_max", param_value: 0.20 },

    # === Signal Weights (weight_in_ti for all 11 signals) ===
    { signal_type: "auth_ratio", category: "default", param_name: "weight_in_ti", param_value: 0.15 },
    { signal_type: "chatter_ccv_ratio", category: "default", param_name: "weight_in_ti", param_value: 0.10 },
    { signal_type: "ccv_step_function", category: "default", param_name: "weight_in_ti", param_value: 0.12 },
    { signal_type: "ccv_tier_clustering", category: "default", param_name: "weight_in_ti", param_value: 0.10 },
    { signal_type: "chat_behavior", category: "default", param_name: "weight_in_ti", param_value: 0.12 },
    { signal_type: "channel_protection_score", category: "default", param_name: "weight_in_ti", param_value: 0.05 },
    { signal_type: "cross_channel_presence", category: "default", param_name: "weight_in_ti", param_value: 0.08 },
    { signal_type: "known_bot_match", category: "default", param_name: "weight_in_ti", param_value: 0.10 },
    { signal_type: "raid_attribution", category: "default", param_name: "weight_in_ti", param_value: 0.06 },
    { signal_type: "ccv_chat_correlation", category: "default", param_name: "weight_in_ti", param_value: 0.07 },
    { signal_type: "account_profile_scoring", category: "default", param_name: "weight_in_ti", param_value: 0.05 },

    # === Alert Thresholds (FR-017) ===
    { signal_type: "auth_ratio", category: "default", param_name: "alert_threshold", param_value: 0.5 },
    { signal_type: "chatter_ccv_ratio", category: "default", param_name: "alert_threshold", param_value: 0.5 },
    { signal_type: "ccv_step_function", category: "default", param_name: "alert_threshold", param_value: 0.5 },
    { signal_type: "ccv_tier_clustering", category: "default", param_name: "alert_threshold", param_value: 0.6 },
    { signal_type: "chat_behavior", category: "default", param_name: "alert_threshold", param_value: 0.5 },
    # Phase 4 J PR-A (2026-06-03, CR iter-1 Must Fix #2): channel_protection_score
    # alert_threshold removed. CPS measures owner-side protective settings, not
    # chatter-side bot risk — an honest streamer with open chat is not anomalous, so
    # waking an operator on it = noise, not alert. The other 7 chatter-side signals
    # carry the bot-detection load. Removal supersedes the prior threshold=0.8 which
    # became unreachable when CPS signal max dropped 1.0 → 0.3 in this PR.
    { signal_type: "cross_channel_presence", category: "default", param_name: "alert_threshold", param_value: 0.3 },
    { signal_type: "known_bot_match", category: "default", param_name: "alert_threshold", param_value: 0.2 },
    { signal_type: "raid_attribution", category: "default", param_name: "alert_threshold", param_value: 0.5 },
    { signal_type: "ccv_chat_correlation", category: "default", param_name: "alert_threshold", param_value: 0.5 },
    { signal_type: "account_profile_scoring", category: "default", param_name: "alert_threshold", param_value: 0.4 },

    # === TASK-029: Trust Index Engine configs ===
    { signal_type: "trust_index", category: "default", param_name: "population_mean", param_value: 65.0 },
    { signal_type: "trust_index", category: "default", param_name: "incident_threshold", param_value: 40.0 },
    { signal_type: "trust_index", category: "default", param_name: "engagement_percentile_threshold", param_value: 80.0 },
    # Classification thresholds (QDC: from DB, not hardcoded)
    { signal_type: "trust_index", category: "default", param_name: "trusted_min", param_value: 80.0 },
    { signal_type: "trust_index", category: "default", param_name: "needs_review_min", param_value: 50.0 },
    { signal_type: "trust_index", category: "default", param_name: "suspicious_min", param_value: 25.0 },

    # === TASK-030: Signal Compute Worker configs ===
    { signal_type: "signal_compute", category: "default", param_name: "throttle_seconds", param_value: 30.0 },

    # === TASK-031: API configs ===
    { signal_type: "api", category: "default", param_name: "channels_per_page", param_value: 20.0 }
  ]

  signal_configs.each do |config|
    record = SignalConfiguration.find_or_initialize_by(
      signal_type: config[:signal_type],
      category: config[:category],
      param_name: config[:param_name]
    )
    record.param_value = config[:param_value]
    record.save!
  end

  # Phase 4 J PR-A (2026-06-03, CR iter-1 Must Fix #2): clean up the obsolete CPS
  # alert_threshold row from prior seeds. Without this delete, re-running seeds
  # leaves a dead threshold=0.8 row that the AnomalyAlerter would never trigger
  # against (signal max is now 0.3). Idempotent — no-op if row already absent.
  SignalConfiguration.where(
    signal_type: "channel_protection_score",
    category: "default",
    param_name: "alert_threshold"
  ).delete_all
  # rubocop:enable Metrics/BlockLength

  puts "Seed complete: #{SignalConfiguration.count} signal configurations"
end

# TASK-085 PG W-2: chatter_ccv_ratio category baselines (moved out of migration #3 per
# CLAUDE.md "Нет данных в миграциях"). Idempotent via find_or_initialize_by.
#
# PG M-3 declined: defined? guard parallels TASK-028 SignalConfiguration block above
# (line 27) — intra-file consistency for the same model. Guard protects transient envs
# (test rollback, partial migration state, rails runner edge cases) where SignalConfiguration
# constant may not be loaded yet. Core domain models (User/Channel/Stream) skip guard
# because they're loaded eagerly; DB-driven config models guard defensively.
if defined?(SignalConfiguration)
  load Rails.root.join("db/seeds/chatter_ccv_baselines.rb")
  baseline_count = SignalConfiguration.where(signal_type: "chatter_ccv_ratio",
                                             param_name: %w[baseline_min baseline_max]).count
  puts "Seed complete: #{baseline_count} chatter_ccv_ratio baselines (PG W-2)"
end
