# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_03_31_300001) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"
  enable_extension "pgcrypto"

  create_table "anomalies", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "anomaly_type", limit: 30, null: false
    t.string "cause", limit: 30
    t.integer "ccv_impact"
    t.decimal "confidence", precision: 5, scale: 4
    t.jsonb "details", default: {}
    t.uuid "stream_id", null: false
    t.datetime "timestamp", null: false
    t.index ["stream_id", "timestamp"], name: "idx_anomalies_stream_time"
    t.index ["stream_id"], name: "index_anomalies_on_stream_id"
  end

  create_table "api_keys", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.boolean "is_active", default: true, null: false
    t.string "key_hash", limit: 255, null: false
    t.datetime "last_used_at"
    t.string "name", limit: 255, null: false
    t.integer "rate_limit", default: 20, null: false
    t.jsonb "scopes", default: []
    t.datetime "updated_at", null: false
    t.uuid "user_id", null: false
    t.index ["key_hash"], name: "index_api_keys_on_key_hash", unique: true
    t.index ["user_id"], name: "index_api_keys_on_user_id"
  end

  create_table "auth_events", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "error_type", limit: 50
    t.string "extension_version", limit: 20
    t.inet "ip_address"
    t.jsonb "metadata", default: {}, null: false
    t.string "provider", limit: 20, null: false
    t.string "result", limit: 20, null: false
    t.text "user_agent"
    t.uuid "user_id"
    t.index ["ip_address", "created_at"], name: "idx_auth_events_ip_time"
    t.index ["provider", "result", "created_at"], name: "idx_auth_events_provider_result_time"
    t.index ["user_id", "created_at"], name: "idx_auth_events_user_time"
  end

  create_table "auth_providers", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.text "access_token"
    t.datetime "created_at", null: false
    t.datetime "expires_at"
    t.boolean "is_broadcaster", default: false, null: false
    t.string "provider", limit: 20, null: false
    t.string "provider_id", limit: 255, null: false
    t.text "refresh_token"
    t.jsonb "scopes", default: []
    t.datetime "updated_at", null: false
    t.uuid "user_id", null: false
    t.index ["provider", "provider_id"], name: "index_auth_providers_on_provider_and_provider_id", unique: true
    t.index ["user_id"], name: "index_auth_providers_on_user_id"
  end

  create_table "billing_events", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.decimal "amount", precision: 10, scale: 2
    t.datetime "created_at", null: false
    t.string "currency", limit: 3
    t.string "event_type", limit: 50, null: false
    t.jsonb "metadata", default: {}, null: false
    t.string "provider", limit: 20, null: false
    t.string "provider_event_id", limit: 255, null: false
    t.datetime "updated_at", null: false
    t.uuid "user_id", null: false
    t.index ["provider_event_id"], name: "idx_billing_events_provider_event", unique: true
    t.index ["user_id", "created_at"], name: "idx_billing_events_user_time"
  end

  create_table "ccv_snapshots", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.integer "ccv_count", null: false
    t.decimal "confidence", precision: 5, scale: 4
    t.integer "real_viewers_estimate"
    t.uuid "stream_id", null: false
    t.datetime "timestamp", null: false
    t.index ["stream_id", "timestamp"], name: "idx_ccv_snapshots_stream_time"
    t.index ["stream_id"], name: "index_ccv_snapshots_on_stream_id"
    t.index ["timestamp"], name: "index_ccv_snapshots_on_timestamp"
  end

  create_table "channel_protection_configs", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "channel_id", null: false
    t.decimal "channel_protection_score", precision: 5, scale: 2
    t.boolean "email_verification_required", default: false, null: false
    t.boolean "emote_only_enabled", default: false, null: false
    t.integer "followers_only_duration_min"
    t.datetime "last_checked_at"
    t.integer "minimum_account_age_minutes"
    t.boolean "phone_verification_required", default: false, null: false
    t.boolean "restrict_first_time_chatters", default: false, null: false
    t.integer "slow_mode_seconds"
    t.boolean "subs_only_enabled", default: false, null: false
    t.index ["channel_id"], name: "index_channel_protection_configs_on_channel_id", unique: true
  end

  create_table "channels", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "broadcaster_type", limit: 20
    t.datetime "created_at", null: false
    t.datetime "deleted_at"
    t.text "description"
    t.string "display_name", limit: 255
    t.integer "followers_total", default: 0
    t.boolean "is_monitored", default: false, null: false
    t.string "login", limit: 255, null: false
    t.text "profile_image_url"
    t.datetime "twitch_account_created_at"
    t.string "twitch_id", limit: 50, null: false
    t.datetime "updated_at", null: false
    t.index ["deleted_at"], name: "index_channels_on_deleted_at"
    t.index ["is_monitored"], name: "index_channels_on_is_monitored"
    t.index ["login"], name: "idx_channels_login", unique: true
    t.index ["login"], name: "index_channels_on_login"
    t.index ["twitch_id"], name: "index_channels_on_twitch_id", unique: true
  end

  create_table "chat_messages", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "badge_info", limit: 255
    t.integer "bits_used", default: 0
    t.string "channel_login", limit: 255, null: false
    t.string "color", limit: 7
    t.string "display_name", limit: 255
    t.text "emotes"
    t.decimal "entropy", precision: 8, scale: 4
    t.boolean "is_first_msg", default: false, null: false
    t.text "message_text"
    t.string "msg_type", limit: 20, default: "privmsg", null: false
    t.jsonb "raw_tags", default: {}, null: false
    t.boolean "returning_chatter", default: false, null: false
    t.uuid "stream_id"
    t.string "subscriber_status", limit: 10
    t.datetime "timestamp", null: false
    t.string "twitch_msg_id", limit: 255
    t.string "user_type", limit: 10
    t.string "username", limit: 255, null: false
    t.boolean "vip", default: false, null: false
    t.index ["channel_login", "timestamp"], name: "idx_chat_messages_channel_time"
    t.index ["channel_login"], name: "idx_chat_messages_channel_login"
    t.index ["msg_type"], name: "idx_chat_messages_msg_type"
    t.index ["stream_id", "timestamp"], name: "idx_chat_messages_stream_time"
    t.index ["stream_id", "username"], name: "idx_chat_messages_stream_username"
    t.index ["stream_id"], name: "index_chat_messages_on_stream_id"
    t.index ["timestamp"], name: "index_chat_messages_on_timestamp"
    t.index ["username"], name: "index_chat_messages_on_username"
  end

  create_table "chatters_snapshots", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.decimal "auth_ratio", precision: 5, scale: 4
    t.uuid "stream_id", null: false
    t.datetime "timestamp", null: false
    t.integer "total_messages_count", null: false
    t.integer "unique_chatters_count", null: false
    t.index ["stream_id", "timestamp"], name: "idx_chatters_snapshots_stream_time"
    t.index ["stream_id"], name: "index_chatters_snapshots_on_stream_id"
  end

  create_table "cross_channel_presences", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "channel_id", null: false
    t.datetime "first_seen_at", null: false
    t.datetime "last_seen_at", null: false
    t.integer "message_count", default: 0, null: false
    t.uuid "stream_id"
    t.string "username", limit: 255, null: false
    t.index ["channel_id", "stream_id"], name: "idx_cross_channel_channel_stream"
    t.index ["username", "channel_id"], name: "idx_cross_channel_user_channel", unique: true
  end

  create_table "erv_estimates", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.decimal "confidence", precision: 5, scale: 4
    t.integer "erv_count", null: false
    t.decimal "erv_percent", precision: 5, scale: 2, null: false
    t.string "label", limit: 30
    t.uuid "stream_id", null: false
    t.datetime "timestamp", null: false
    t.index ["stream_id", "timestamp"], name: "idx_erv_estimates_stream_time"
    t.index ["stream_id"], name: "index_erv_estimates_on_stream_id"
  end

  create_table "flipper_features", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "key", null: false
    t.datetime "updated_at", null: false
    t.index ["key"], name: "index_flipper_features_on_key", unique: true
  end

  create_table "flipper_gates", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "feature_key", null: false
    t.string "key", null: false
    t.datetime "updated_at", null: false
    t.text "value"
    t.index ["feature_key", "key", "value"], name: "idx_flipper_gates_feature_key_value", unique: true
  end

  create_table "follower_snapshots", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "channel_id", null: false
    t.integer "followers_count", null: false
    t.integer "new_followers_24h"
    t.datetime "timestamp", null: false
    t.index ["channel_id", "timestamp"], name: "idx_follower_snapshots_channel_time"
  end

  create_table "health_scores", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "calculated_at", null: false
    t.uuid "channel_id", null: false
    t.string "confidence_level", limit: 20
    t.decimal "consistency_component", precision: 5, scale: 2
    t.decimal "engagement_component", precision: 5, scale: 2
    t.decimal "growth_component", precision: 5, scale: 2
    t.decimal "health_score", precision: 5, scale: 2, null: false
    t.decimal "stability_component", precision: 5, scale: 2
    t.uuid "stream_id"
    t.decimal "ti_component", precision: 5, scale: 2
    t.index ["channel_id"], name: "idx_health_scores_channel"
    t.index ["channel_id"], name: "index_health_scores_on_channel_id"
    t.index ["stream_id"], name: "index_health_scores_on_stream_id"
  end

  create_table "known_bot_lists", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "added_at", null: false
    t.string "bot_category", limit: 20, default: "unknown", null: false
    t.decimal "confidence", precision: 5, scale: 4, null: false
    t.datetime "last_seen_at"
    t.string "source", limit: 30, null: false
    t.string "username", limit: 255, null: false
    t.boolean "verified", default: false, null: false
    t.index ["source"], name: "idx_known_bot_lists_source"
    t.index ["username", "source"], name: "idx_known_bot_lists_username_source", unique: true
  end

  create_table "notifications", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "channel_id"
    t.datetime "created_at", null: false
    t.string "priority", limit: 10
    t.datetime "read_at"
    t.datetime "sent_at"
    t.uuid "stream_id"
    t.string "type", limit: 50, null: false
    t.datetime "updated_at", null: false
    t.uuid "user_id", null: false
    t.index ["channel_id"], name: "index_notifications_on_channel_id"
    t.index ["stream_id"], name: "index_notifications_on_stream_id"
    t.index ["user_id"], name: "idx_notifications_user"
    t.index ["user_id"], name: "index_notifications_on_user_id"
  end

  create_table "pdf_reports", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "channel_id", null: false
    t.datetime "created_at", null: false
    t.datetime "expires_at"
    t.text "file_path"
    t.boolean "is_white_label", default: false, null: false
    t.decimal "price_charged", precision: 10, scale: 2
    t.string "report_type", limit: 20, null: false
    t.string "share_token", limit: 64
    t.datetime "updated_at", null: false
    t.uuid "user_id", null: false
    t.index ["channel_id"], name: "index_pdf_reports_on_channel_id"
    t.index ["share_token"], name: "index_pdf_reports_on_share_token", unique: true
    t.index ["user_id"], name: "index_pdf_reports_on_user_id"
  end

  create_table "per_user_bot_scores", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.decimal "bot_score", precision: 5, scale: 4, null: false
    t.string "classification", limit: 20, default: "unknown", null: false
    t.jsonb "components", default: {}
    t.decimal "confidence", precision: 5, scale: 4
    t.uuid "stream_id", null: false
    t.string "user_id", limit: 50
    t.string "username", limit: 255, null: false
    t.index ["stream_id", "classification"], name: "idx_bot_scores_stream_classification"
    t.index ["stream_id", "username"], name: "idx_bot_scores_stream_username", unique: true
    t.index ["stream_id"], name: "idx_per_user_bot_scores_stream"
    t.index ["stream_id"], name: "index_per_user_bot_scores_on_stream_id"
    t.index ["username"], name: "index_per_user_bot_scores_on_username"
  end

  create_table "post_stream_reports", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.jsonb "anomalies", default: []
    t.integer "ccv_avg"
    t.integer "ccv_peak"
    t.bigint "duration_ms"
    t.integer "erv_final"
    t.decimal "erv_percent_final", precision: 5, scale: 2
    t.datetime "generated_at", null: false
    t.jsonb "signals_summary", default: {}
    t.uuid "stream_id", null: false
    t.decimal "trust_index_final", precision: 5, scale: 2
    t.index ["stream_id"], name: "index_post_stream_reports_on_stream_id", unique: true
  end

  create_table "predictions_polls", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.integer "ccv_at_time"
    t.string "event_type", limit: 20, null: false
    t.integer "participants_count", null: false
    t.decimal "participation_ratio", precision: 5, scale: 4
    t.uuid "stream_id", null: false
    t.datetime "timestamp", null: false
    t.index ["stream_id", "timestamp"], name: "idx_predictions_polls_stream_time"
  end

  create_table "raid_attributions", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.decimal "bot_score", precision: 5, scale: 4
    t.boolean "is_bot_raid", default: false, null: false
    t.integer "raid_viewers_count"
    t.jsonb "signal_scores", default: {}
    t.uuid "source_channel_id"
    t.uuid "stream_id", null: false
    t.datetime "timestamp", null: false
    t.index ["source_channel_id"], name: "index_raid_attributions_on_source_channel_id"
    t.index ["stream_id", "timestamp"], name: "idx_raid_attributions_stream_time"
    t.index ["stream_id"], name: "index_raid_attributions_on_stream_id"
  end

  create_table "score_disputes", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "channel_id", null: false
    t.text "reason", null: false
    t.datetime "resolution_at"
    t.string "resolution_status", limit: 20, default: "pending", null: false
    t.datetime "submitted_at", null: false
    t.uuid "user_id", null: false
    t.index ["channel_id"], name: "index_score_disputes_on_channel_id"
    t.index ["user_id", "submitted_at"], name: "idx_score_disputes_user_submitted"
    t.index ["user_id"], name: "index_score_disputes_on_user_id"
  end

  create_table "sessions", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "expires_at", null: false
    t.inet "ip_address"
    t.boolean "is_active", default: true, null: false
    t.string "token", limit: 255, null: false
    t.datetime "updated_at", null: false
    t.text "user_agent"
    t.uuid "user_id", null: false
    t.index ["token"], name: "index_sessions_on_token", unique: true
    t.index ["user_id", "is_active"], name: "idx_sessions_user_active"
    t.index ["user_id"], name: "index_sessions_on_user_id"
  end

  create_table "signal_configurations", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "category", limit: 50, null: false
    t.datetime "created_at", null: false
    t.string "param_name", limit: 100, null: false
    t.decimal "param_value", precision: 10, scale: 4, null: false
    t.string "signal_type", limit: 50, null: false
    t.datetime "updated_at", null: false
    t.index ["signal_type", "category", "param_name"], name: "idx_signal_configs_type_category_param", unique: true
  end

  create_table "signals", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "category", limit: 50
    t.decimal "confidence", precision: 5, scale: 4
    t.datetime "created_at", default: -> { "now()" }, null: false
    t.jsonb "metadata", default: {}, null: false
    t.string "signal_type", limit: 50, null: false
    t.uuid "stream_id", null: false
    t.datetime "timestamp", null: false
    t.decimal "value", precision: 10, scale: 4, null: false
    t.decimal "weight_in_ti", precision: 5, scale: 4
    t.index ["signal_type"], name: "index_signals_on_signal_type"
    t.index ["stream_id", "signal_type", "timestamp"], name: "idx_signals_stream_type_timestamp"
    t.index ["stream_id", "timestamp"], name: "idx_signals_stream_time"
    t.index ["stream_id"], name: "index_signals_on_stream_id"
    t.index ["timestamp"], name: "index_signals_on_timestamp"
  end

  create_table "streamer_ratings", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "calculated_at", null: false
    t.uuid "channel_id", null: false
    t.datetime "created_at", null: false
    t.decimal "decay_lambda", precision: 5, scale: 4, default: "0.05", null: false
    t.decimal "rating_score", precision: 5, scale: 2, null: false
    t.integer "streams_count", default: 0, null: false
    t.datetime "updated_at", null: false
    t.index ["channel_id"], name: "index_streamer_ratings_on_channel_id", unique: true
  end

  create_table "streamer_reputations", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "calculated_at", null: false
    t.uuid "channel_id", null: false
    t.decimal "engagement_consistency_score", precision: 5, scale: 2
    t.decimal "follower_quality_score", precision: 5, scale: 2
    t.decimal "growth_pattern_score", precision: 5, scale: 2
    t.index ["channel_id"], name: "index_streamer_reputations_on_channel_id", unique: true
  end

  create_table "streams", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.integer "avg_ccv", default: 0
    t.uuid "channel_id", null: false
    t.datetime "created_at", null: false
    t.bigint "duration_ms"
    t.datetime "ended_at"
    t.string "game_name", limit: 255
    t.boolean "is_mature", default: false, null: false
    t.string "language", limit: 10
    t.string "merge_status", limit: 20, default: "separate"
    t.integer "merged_parts_count", default: 1, null: false
    t.jsonb "part_boundaries", default: [], null: false
    t.integer "peak_ccv", default: 0
    t.datetime "started_at", null: false
    t.text "title"
    t.datetime "updated_at", null: false
    t.index ["channel_id"], name: "index_streams_on_channel_id"
    t.index ["started_at"], name: "index_streams_on_started_at"
  end

  create_table "subscriptions", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "billing_period_end"
    t.datetime "cancelled_at"
    t.datetime "created_at", null: false
    t.boolean "is_active", default: true, null: false
    t.string "plan_type", limit: 20
    t.decimal "price", precision: 10, scale: 2
    t.string "provider_subscription_id", limit: 255
    t.datetime "started_at", null: false
    t.string "tier", limit: 20, default: "free", null: false
    t.datetime "updated_at", null: false
    t.uuid "user_id", null: false
    t.index ["is_active"], name: "index_subscriptions_on_is_active"
    t.index ["provider_subscription_id"], name: "idx_subscriptions_provider_sub_id", unique: true
    t.index ["user_id"], name: "index_subscriptions_on_user_id"
  end

  create_table "team_memberships", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "role", default: "member", null: false
    t.string "status", default: "active", null: false
    t.uuid "team_owner_id", null: false
    t.datetime "updated_at", null: false
    t.uuid "user_id", null: false
    t.index ["team_owner_id"], name: "idx_team_memberships_owner_id"
    t.index ["team_owner_id"], name: "index_team_memberships_on_team_owner_id"
    t.index ["user_id", "team_owner_id"], name: "idx_team_memberships_user_owner", unique: true
    t.index ["user_id"], name: "index_team_memberships_on_user_id"
  end

  create_table "tracked_channels", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "added_at", null: false
    t.uuid "channel_id", null: false
    t.uuid "subscription_id"
    t.boolean "tracking_enabled", default: true, null: false
    t.uuid "user_id", null: false
    t.index ["channel_id"], name: "index_tracked_channels_on_channel_id"
    t.index ["subscription_id"], name: "index_tracked_channels_on_subscription_id"
    t.index ["user_id", "channel_id"], name: "index_tracked_channels_on_user_id_and_channel_id", unique: true
    t.index ["user_id"], name: "index_tracked_channels_on_user_id"
  end

  create_table "trust_index_histories", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "calculated_at", null: false
    t.integer "ccv"
    t.uuid "channel_id", null: false
    t.string "classification", limit: 20
    t.string "cold_start_status", limit: 20
    t.decimal "confidence", precision: 5, scale: 4
    t.decimal "erv_percent", precision: 5, scale: 2
    t.decimal "rehabilitation_bonus", precision: 5, scale: 2, default: "0.0"
    t.decimal "rehabilitation_penalty", precision: 5, scale: 2, default: "0.0"
    t.jsonb "signal_breakdown", default: {}
    t.uuid "stream_id"
    t.decimal "trust_index_score", precision: 5, scale: 2, null: false
    t.index ["calculated_at"], name: "index_trust_index_histories_on_calculated_at"
    t.index ["channel_id"], name: "idx_ti_histories_channel"
    t.index ["channel_id"], name: "index_trust_index_histories_on_channel_id"
    t.index ["stream_id"], name: "index_trust_index_histories_on_stream_id"
  end

  create_table "user_accounts", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.text "banner_image_url"
    t.datetime "created_at"
    t.text "description"
    t.integer "followers_total"
    t.integer "follows_total"
    t.boolean "is_affiliate", default: false, null: false
    t.boolean "is_partner", default: false, null: false
    t.datetime "last_broadcast_at"
    t.datetime "last_updated_at"
    t.integer "profile_view_count"
    t.string "twitch_id", limit: 50
    t.string "username", limit: 255, null: false
    t.integer "videos_total_count"
    t.index ["twitch_id"], name: "index_user_accounts_on_twitch_id", unique: true
    t.index ["username"], name: "index_user_accounts_on_username", unique: true
  end

  create_table "users", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.text "avatar_url"
    t.datetime "created_at", null: false
    t.datetime "deleted_at"
    t.string "display_name", limit: 255
    t.string "email", limit: 255
    t.string "goal_tag", limit: 20
    t.string "locale", limit: 5, default: "en", null: false
    t.string "role", limit: 20, default: "viewer", null: false
    t.string "tier", limit: 20, default: "free", null: false
    t.datetime "updated_at", null: false
    t.string "username", limit: 255
    t.index ["deleted_at"], name: "index_users_on_deleted_at"
    t.index ["email"], name: "index_users_on_email", unique: true
    t.index ["username"], name: "index_users_on_username", unique: true
  end

  create_table "watchlist_tags_notes", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "added_at", null: false
    t.uuid "channel_id", null: false
    t.text "notes"
    t.jsonb "tags", default: []
    t.uuid "watchlist_id", null: false
    t.index ["channel_id"], name: "index_watchlist_tags_notes_on_channel_id"
    t.index ["watchlist_id"], name: "index_watchlist_tags_notes_on_watchlist_id"
  end

  create_table "watchlists", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.jsonb "channels_list", default: [], null: false
    t.datetime "created_at", null: false
    t.string "name", limit: 255, null: false
    t.datetime "updated_at", null: false
    t.uuid "user_id", null: false
    t.index ["user_id"], name: "idx_watchlists_user"
    t.index ["user_id"], name: "index_watchlists_on_user_id"
  end

  add_foreign_key "anomalies", "streams"
  add_foreign_key "api_keys", "users"
  add_foreign_key "auth_events", "users"
  add_foreign_key "auth_providers", "users"
  add_foreign_key "billing_events", "users"
  add_foreign_key "ccv_snapshots", "streams"
  add_foreign_key "channel_protection_configs", "channels"
  add_foreign_key "chat_messages", "streams"
  add_foreign_key "chatters_snapshots", "streams"
  add_foreign_key "cross_channel_presences", "channels"
  add_foreign_key "cross_channel_presences", "streams"
  add_foreign_key "erv_estimates", "streams"
  add_foreign_key "follower_snapshots", "channels"
  add_foreign_key "health_scores", "channels"
  add_foreign_key "health_scores", "streams"
  add_foreign_key "notifications", "channels"
  add_foreign_key "notifications", "streams"
  add_foreign_key "notifications", "users"
  add_foreign_key "pdf_reports", "channels"
  add_foreign_key "pdf_reports", "users"
  add_foreign_key "per_user_bot_scores", "streams"
  add_foreign_key "post_stream_reports", "streams"
  add_foreign_key "predictions_polls", "streams"
  add_foreign_key "raid_attributions", "channels", column: "source_channel_id"
  add_foreign_key "raid_attributions", "streams"
  add_foreign_key "score_disputes", "channels"
  add_foreign_key "score_disputes", "users"
  add_foreign_key "sessions", "users"
  add_foreign_key "signals", "streams"
  add_foreign_key "streamer_ratings", "channels"
  add_foreign_key "streamer_reputations", "channels"
  add_foreign_key "streams", "channels"
  add_foreign_key "subscriptions", "users"
  add_foreign_key "team_memberships", "users"
  add_foreign_key "team_memberships", "users", column: "team_owner_id"
  add_foreign_key "tracked_channels", "channels"
  add_foreign_key "tracked_channels", "subscriptions"
  add_foreign_key "tracked_channels", "users"
  add_foreign_key "trust_index_histories", "channels"
  add_foreign_key "trust_index_histories", "streams"
  add_foreign_key "watchlist_tags_notes", "channels"
  add_foreign_key "watchlist_tags_notes", "watchlists"
  add_foreign_key "watchlists", "users"
end
