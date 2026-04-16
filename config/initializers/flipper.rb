# frozen_string_literal: true

require "flipper"
require "flipper/adapters/redis"
require "flipper/adapters/active_record"
require "flipper/adapters/memoizable"

# Fail fast: FLIPPER_UI_PASSWORD required in production
if Rails.env.production? && ENV["FLIPPER_UI_PASSWORD"].blank?
  raise "FLIPPER_UI_PASSWORD must be set in production"
end

# Primary: Redis (fast). Fallback: ActiveRecord (durable).
# Memoize: per-request cache on top.
redis_url = ENV.fetch("REDIS_URL", "redis://localhost:6379/1")

begin
  redis_instance = Redis.new(url: redis_url)
  redis_instance.ping
  redis_adapter = Flipper::Adapters::Redis.new(redis_instance)
rescue Redis::CannotConnectError, Redis::TimeoutError => e
  Rails.logger.error("Flipper: Redis unavailable (#{e.message}), using ActiveRecord only")
  redis_adapter = nil
end

ar_adapter = Flipper::Adapters::ActiveRecord.new

primary_adapter = redis_adapter || ar_adapter
memoized = Flipper::Adapters::Memoizable.new(primary_adapter)

Flipper.configure do |config|
  config.adapter { memoized }
end

# Instrumenter for audit logging
ActiveSupport::Notifications.subscribe(/flipper/) do |name, _start, _finish, _id, payload|
  next unless name.include?("feature_operation")

  Rails.logger.info(
    "Flipper audit: operation=#{payload[:operation]} " \
    "feature=#{payload[:feature_name]} " \
    "gate=#{payload[:gate_name]} " \
    "thing=#{payload[:thing]}"
  )
end

# Groups (per BRD BR-005)
Flipper.register(:premium_users) do |actor|
  actor.respond_to?(:tier) && actor.tier == "premium"
end

Flipper.register(:business_users) do |actor|
  actor.respond_to?(:tier) && actor.tier == "business"
end

Flipper.register(:streamers) do |actor|
  actor.respond_to?(:role) && actor.role == "streamer"
end

# Single source of truth for all feature flags.
# Paywall enforcement = Pundit policies. Flipper = kill switches only.
# Default state = enabled. Disable only in emergency.
module FlipperDefaults
  ALL_FLAGS = %i[
    pundit_authorization
    bot_raid_chain
    compare_unlimited
    audience_overlap
    ad_calculator
    social_presence
    panel_tracking
    tracking_requests
    irc_monitor
    stream_monitor
    known_bots
    channel_discovery
    bot_scoring
    signal_compute
    hs_recommendations
  ].freeze
end

# On every boot: ensure all flags exist and are enabled.
# No manual steps. No "one-time scripts". Deploy = correct state.
# Emergency disable: Flipper.disable(:flag) holds until next deploy.
# When the fix is deployed → container restarts → flag back to enabled. Correct behavior.
FlipperDefaults::ALL_FLAGS.each do |flag|
  Flipper.add(flag)
  Flipper.enable(flag)
end
