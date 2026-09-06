# frozen_string_literal: true

# TASK-033: Async Telegram alert delivery.
# Sidekiq handles retry with exponential backoff on failure.
# Used by TiDivergenceAlerter (and future internal alerts).

class TelegramAlertWorker
  include Sidekiq::Job
  sidekiq_options queue: :notifications, retry: 5

  TIMEOUT = 5 # seconds

  def perform(text)
    bot_token = ENV["TELEGRAM_BOT_TOKEN"]
    chat_id = ENV["TELEGRAM_ALERT_CHAT_ID"]

    unless bot_token.present? && chat_id.present?
      Rails.logger.warn("TelegramAlertWorker: TELEGRAM_BOT_TOKEN or CHAT_ID not configured")
      return
    end

    uri = URI("https://api.telegram.org/bot#{bot_token}/sendMessage")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.open_timeout = TIMEOUT
    http.read_timeout = TIMEOUT
    # The server ISP blocks the Telegram DC subnet the public DNS A/AAAA records point at,
    # while other official DC IPs stay reachable. TELEGRAM_API_IPADDR pins the connect IP
    # (TLS SNI/verification still use the hostname). Empty env = normal DNS resolution.
    # Re-probe on delivery failures: curl --resolve api.telegram.org:443:<ip> https://api.telegram.org/
    http.ipaddr = ENV["TELEGRAM_API_IPADDR"] if ENV["TELEGRAM_API_IPADDR"].present?

    request = Net::HTTP::Post.new(uri)
    request.content_type = "application/json"
    request.body = { chat_id: chat_id, text: text, parse_mode: "HTML" }.to_json

    response = http.request(request)

    unless response.is_a?(Net::HTTPSuccess)
      raise "Telegram API HTTP #{response.code}: #{response.body.truncate(200)}"
    end

    Rails.logger.info("TelegramAlertWorker: message sent (#{text.truncate(50)})")
  end
end
