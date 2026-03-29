# frozen_string_literal: true

# TASK-023: Twitch EventSub Subscription Management
# Creates/deletes EventSub webhook subscriptions via Helix API.
# Uses App Access Token from HelixClient.
#
# 5 event types per channel: stream.online, stream.offline,
# channel.raid, channel.update, channel.follow

module Twitch
  class EventSubService
    WEBHOOK_URL_BASE = ENV.fetch("EVENTSUB_WEBHOOK_URL") {
      Rails.env.production? ? raise("EVENTSUB_WEBHOOK_URL must be set in production") : "https://staging.himrate.com/webhooks/twitch"
    }

    EVENT_TYPES = {
      "stream.online" => { version: "1", condition_key: "broadcaster_user_id" },
      "stream.offline" => { version: "1", condition_key: "broadcaster_user_id" },
      "channel.raid" => { version: "1", condition_key: "to_broadcaster_user_id" },
      "channel.update" => { version: "2", condition_key: "broadcaster_user_id" },
      "channel.follow" => { version: "2", condition_key: "broadcaster_user_id" }
    }.freeze

    class Error < StandardError; end

    def initialize
      @helix = Twitch::HelixClient.new
      @secret = ENV.fetch("TWITCH_WEBHOOK_SECRET") {
        Rails.env.production? ? raise("TWITCH_WEBHOOK_SECRET must be set in production") : "dev_webhook_secret_min10chars"
      }
    end

    # FR-010: Subscribe to all 5 event types for a channel
    def subscribe(broadcaster_id:)
      results = EVENT_TYPES.map do |type, config|
        create_subscription(
          type: type,
          version: config[:version],
          condition: { config[:condition_key] => broadcaster_id }
        )
      end

      successful = results.compact
      Rails.logger.info("EventSub: subscribed #{successful.size}/#{EVENT_TYPES.size} for broadcaster #{broadcaster_id}")
      successful
    end

    # FR-011: Unsubscribe all subscriptions for a channel
    def unsubscribe(broadcaster_id:)
      subs = list_subscriptions
      return 0 unless subs

      channel_subs = subs.select do |sub|
        sub.dig("condition", "broadcaster_user_id") == broadcaster_id ||
          sub.dig("condition", "to_broadcaster_user_id") == broadcaster_id
      end

      deleted = channel_subs.count do |sub|
        delete_subscription(sub["id"])
      end

      Rails.logger.info("EventSub: unsubscribed #{deleted}/#{channel_subs.size} for broadcaster #{broadcaster_id}")
      deleted
    end

    # List all current subscriptions
    def list_subscriptions
      token = @helix.send(:fetch_app_token)
      response = HTTP.timeout(5).headers(
        "Client-ID" => ENV.fetch("TWITCH_CLIENT_ID"),
        "Authorization" => "Bearer #{token}"
      ).get("https://api.twitch.tv/helix/eventsub/subscriptions")

      return nil unless response.status.to_i == 200

      JSON.parse(response.body.to_s).dig("data")
    rescue HTTP::Error => e
      Rails.logger.error("EventSub list error: #{e.message}")
      nil
    end

    private

    def create_subscription(type:, version:, condition:)
      token = @helix.send(:fetch_app_token)

      body = {
        type: type,
        version: version,
        condition: condition,
        transport: {
          method: "webhook",
          callback: WEBHOOK_URL_BASE,
          secret: @secret
        }
      }

      response = HTTP.timeout(5).headers(
        "Client-ID" => ENV.fetch("TWITCH_CLIENT_ID"),
        "Authorization" => "Bearer #{token}",
        "Content-Type" => "application/json"
      ).post("https://api.twitch.tv/helix/eventsub/subscriptions", json: body)

      case response.status.to_i
      when 202
        data = JSON.parse(response.body.to_s)
        Rails.logger.info("EventSub: created #{type} subscription")
        data.dig("data", 0, "id")
      when 409
        Rails.logger.warn("EventSub: #{type} subscription already exists")
        "existing"
      else
        Rails.logger.error("EventSub: failed to create #{type} — #{response.status}: #{response.body.to_s.truncate(200)}")
        nil
      end
    rescue HTTP::Error => e
      Rails.logger.error("EventSub create error: #{type} — #{e.message}")
      nil
    end

    def delete_subscription(subscription_id)
      token = @helix.send(:fetch_app_token)

      response = HTTP.timeout(5).headers(
        "Client-ID" => ENV.fetch("TWITCH_CLIENT_ID"),
        "Authorization" => "Bearer #{token}"
      ).delete("https://api.twitch.tv/helix/eventsub/subscriptions?id=#{subscription_id}")

      response.status.to_i == 204
    rescue HTTP::Error => e
      Rails.logger.error("EventSub delete error: #{subscription_id} — #{e.message}")
      false
    end
  end
end
