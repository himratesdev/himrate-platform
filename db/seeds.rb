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
    { signal_type: "auth_ratio", category: "just_chatting", param_name: "expected_min", param_value: 0.75 },
    { signal_type: "auth_ratio", category: "just_chatting", param_name: "expected_max", param_value: 0.90 },
    { signal_type: "auth_ratio", category: "esports", param_name: "expected_min", param_value: 0.58 },
    { signal_type: "auth_ratio", category: "esports", param_name: "expected_max", param_value: 0.74 },
    { signal_type: "auth_ratio", category: "gaming", param_name: "expected_min", param_value: 0.65 },
    { signal_type: "auth_ratio", category: "gaming", param_name: "expected_max", param_value: 0.80 },
    { signal_type: "auth_ratio", category: "irl", param_name: "expected_min", param_value: 0.70 },
    { signal_type: "auth_ratio", category: "irl", param_name: "expected_max", param_value: 0.85 },
    { signal_type: "auth_ratio", category: "music", param_name: "expected_min", param_value: 0.60 },
    { signal_type: "auth_ratio", category: "music", param_name: "expected_max", param_value: 0.78 },
    { signal_type: "auth_ratio", category: "default", param_name: "expected_min", param_value: 0.65 },
    { signal_type: "auth_ratio", category: "default", param_name: "expected_max", param_value: 0.80 },

    # === Chatter-to-CCV Ratio (Signal #2) — BFT §5.2 ===
    { signal_type: "chatter_ccv_ratio", category: "just_chatting", param_name: "expected_ratio_min", param_value: 0.20 },
    { signal_type: "chatter_ccv_ratio", category: "just_chatting", param_name: "expected_ratio_max", param_value: 0.33 },
    { signal_type: "chatter_ccv_ratio", category: "esports", param_name: "expected_ratio_min", param_value: 0.02 },
    { signal_type: "chatter_ccv_ratio", category: "esports", param_name: "expected_ratio_max", param_value: 0.067 },
    { signal_type: "chatter_ccv_ratio", category: "gaming", param_name: "expected_ratio_min", param_value: 0.10 },
    { signal_type: "chatter_ccv_ratio", category: "gaming", param_name: "expected_ratio_max", param_value: 0.20 },
    { signal_type: "chatter_ccv_ratio", category: "irl", param_name: "expected_ratio_min", param_value: 0.125 },
    { signal_type: "chatter_ccv_ratio", category: "irl", param_name: "expected_ratio_max", param_value: 0.25 },
    { signal_type: "chatter_ccv_ratio", category: "music", param_name: "expected_ratio_min", param_value: 0.067 },
    { signal_type: "chatter_ccv_ratio", category: "music", param_name: "expected_ratio_max", param_value: 0.15 },
    { signal_type: "chatter_ccv_ratio", category: "default", param_name: "expected_ratio_min", param_value: 0.10 },
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
    { signal_type: "channel_protection_score", category: "default", param_name: "alert_threshold", param_value: 0.8 },
    { signal_type: "cross_channel_presence", category: "default", param_name: "alert_threshold", param_value: 0.3 },
    { signal_type: "known_bot_match", category: "default", param_name: "alert_threshold", param_value: 0.2 },
    { signal_type: "raid_attribution", category: "default", param_name: "alert_threshold", param_value: 0.5 },
    { signal_type: "ccv_chat_correlation", category: "default", param_name: "alert_threshold", param_value: 0.5 },
    { signal_type: "account_profile_scoring", category: "default", param_name: "alert_threshold", param_value: 0.4 },

    # === TASK-029: Trust Index Engine configs ===
    { signal_type: "trust_index", category: "default", param_name: "population_mean", param_value: 65.0 },
    { signal_type: "trust_index", category: "default", param_name: "incident_threshold", param_value: 40.0 },
    { signal_type: "trust_index", category: "default", param_name: "rehabilitation_streams", param_value: 15.0 },
    { signal_type: "trust_index", category: "default", param_name: "rehabilitation_bonus_max", param_value: 15.0 },
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
  # rubocop:enable Metrics/BlockLength

  puts "Seed complete: #{SignalConfiguration.count} signal configurations"
end

# TASK-038: Health Score seed data (tiers, categories, recommendation templates)
if defined?(HealthScoreTier) && defined?(HealthScoreCategory) && defined?(RecommendationTemplate)
  load Rails.root.join("db/seeds/health_score.rb")
  HealthScoreSeeds.run
  puts "Seed complete: #{HealthScoreTier.count} tiers, #{HealthScoreCategory.count} categories, " \
       "#{RecommendationTemplate.count} recommendation templates"
end
