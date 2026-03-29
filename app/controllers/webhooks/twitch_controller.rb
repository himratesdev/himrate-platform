# frozen_string_literal: true

# TASK-023: Twitch EventSub Webhook Receiver
# HMAC-SHA256 verification + challenge response + event routing to Sidekiq.
# CRITICAL SECURITY: Every request MUST be verified before processing.

module Webhooks
  class TwitchController < ActionController::API
    before_action :verify_hmac_signature
    before_action :check_idempotency, only: :create

    WEBHOOK_SECRET = ENV.fetch("TWITCH_WEBHOOK_SECRET") {
      Rails.env.production? ? raise("TWITCH_WEBHOOK_SECRET required") : "dev_webhook_secret_min10chars"
    }
    MESSAGE_TTL = 10.minutes
    STALE_THRESHOLD = 10.minutes

    # Worker mapping: event type → Sidekiq worker class
    WORKER_MAP = {
      "stream.online" => "StreamOnlineWorker",
      "stream.offline" => "StreamOfflineWorker",
      "channel.raid" => "RaidWorker",
      "channel.update" => "ChannelUpdateWorker",
      "channel.follow" => "FollowWorker"
    }.freeze

    def create
      message_type = request.headers["Twitch-Eventsub-Message-Type"]

      case message_type
      when "webhook_callback_verification"
        handle_challenge
      when "notification"
        handle_notification
      when "revocation"
        handle_revocation
      else
        Rails.logger.warn("EventSub: unknown message_type=#{message_type}")
        head :ok
      end
    end

    private

    # === FR-001: HMAC-SHA256 Verification ===

    def verify_hmac_signature
      message_id = request.headers["Twitch-Eventsub-Message-Id"]
      timestamp = request.headers["Twitch-Eventsub-Message-Timestamp"]
      signature = request.headers["Twitch-Eventsub-Message-Signature"]

      unless message_id && timestamp && signature
        Rails.logger.warn("EventSub: missing HMAC headers from #{request.remote_ip}")
        return head :forbidden
      end

      # Stale message check (replay attack protection)
      if Time.parse(timestamp) < STALE_THRESHOLD.ago
        Rails.logger.warn("EventSub: stale message (#{timestamp}) from #{request.remote_ip}")
        return head :forbidden
      end

      raw_body = request.body.read
      request.body.rewind

      hmac_message = "#{message_id}#{timestamp}#{raw_body}"
      expected = "sha256=" + OpenSSL::HMAC.hexdigest("SHA256", WEBHOOK_SECRET, hmac_message)

      unless ActiveSupport::SecurityUtils.secure_compare(expected, signature)
        Rails.logger.warn("EventSub: HMAC mismatch from #{request.remote_ip}")
        head :forbidden
      end
    rescue ArgumentError => e
      Rails.logger.warn("EventSub: invalid timestamp #{timestamp} — #{e.message}")
      head :forbidden
    end

    # === FR-003: Idempotency ===

    def check_idempotency
      message_id = request.headers["Twitch-Eventsub-Message-Id"]
      return unless message_id

      key = "eventsub:msg:#{message_id}"
      already_processed = redis&.set(key, "1", nx: true, ex: MESSAGE_TTL.to_i) == false

      if already_processed
        Rails.logger.debug("EventSub: duplicate message_id=#{message_id}")
        head :ok
      end
    end

    # === FR-002: Challenge Response ===

    def handle_challenge
      body = JSON.parse(request.body.read)
      challenge = body["challenge"]

      Rails.logger.info("EventSub: challenge received for #{body.dig("subscription", "type")}")
      render plain: challenge, status: :ok
    end

    # === FR-004: Event Routing ===

    def handle_notification
      body = JSON.parse(request.body.read)
      event_type = body.dig("subscription", "type")
      event_data = body["event"]

      worker_class = WORKER_MAP[event_type]

      if worker_class
        worker_class.constantize.perform_async(event_data)
        Rails.logger.info("EventSub: routed #{event_type} → #{worker_class} broadcaster=#{event_data&.dig("broadcaster_user_id")}")
      else
        Rails.logger.warn("EventSub: unknown event_type=#{event_type}")
      end

      head :ok
    rescue JSON::ParserError => e
      Rails.logger.error("EventSub: malformed JSON — #{e.message}")
      head :bad_request
    end

    # === FR-012: Revocation ===

    def handle_revocation
      body = JSON.parse(request.body.read)
      sub_type = body.dig("subscription", "type")
      sub_id = body.dig("subscription", "id")
      reason = body.dig("subscription", "status")

      Rails.logger.warn("EventSub: revocation type=#{sub_type} id=#{sub_id} reason=#{reason}")
      head :ok
    rescue JSON::ParserError
      head :ok
    end

    def redis
      @redis ||= begin
        r = Redis.new(url: ENV.fetch("REDIS_URL", "redis://localhost:6379/1"))
        r.ping
        r
      rescue Redis::CannotConnectError, Redis::TimeoutError => e
        Rails.logger.warn("EventSub: Redis unavailable (#{e.message}), idempotency disabled")
        nil
      end
    end
  end
end
