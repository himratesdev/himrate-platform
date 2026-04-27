# frozen_string_literal: true

# BUG-010 PR2 (FR-070/073): push alerts → Alertmanager API.
# Replaces direct Telegram POST для workflow + worker — Alertmanager handles severity routing
# через alertmanager.yml routing tree (telegram_critical/ops/info per BR-021).
#
# Fallback (Alertmanager down): direct Telegram POST к telegram_critical channel as last resort.

require "net/http"

class AlertmanagerNotifier
  ALERTMANAGER_URL = "http://himrate-alertmanager:9093/api/v2/alerts"
  PUSH_TIMEOUT_SECONDS = 5
  RETRY_DELAYS = [ 2, 4, 8 ].freeze

  def self.push(labels:, annotations:)
    payload = [ { labels: labels.transform_keys(&:to_s), annotations: annotations.transform_keys(&:to_s) } ]
    json = JSON.generate(payload)

    RETRY_DELAYS.each_with_index do |delay, attempt|
      response = post_to_alertmanager(json)
      return :ok if response&.code == "200"

      if attempt < RETRY_DELAYS.size - 1
        sleep(delay)
        next
      end

      Rails.logger.warn("AlertmanagerNotifier: push failed после #{RETRY_DELAYS.size} retries — fallback к direct Telegram")
      return fallback_telegram(labels: labels, annotations: annotations)
    end
  end

  def self.post_to_alertmanager(json)
    uri = URI(ALERTMANAGER_URL)
    request = Net::HTTP::Post.new(uri, "Content-Type" => "application/json")
    request.body = json

    Net::HTTP.start(uri.hostname, uri.port,
                    open_timeout: PUSH_TIMEOUT_SECONDS,
                    read_timeout: PUSH_TIMEOUT_SECONDS) { |http| http.request(request) }
  rescue StandardError => e
    Rails.logger.warn("AlertmanagerNotifier: Alertmanager unreachable — #{e.class}: #{e.message}")
    nil
  end

  def self.fallback_telegram(labels:, annotations:)
    bot_token = ENV["TELEGRAM_OPS_BOT_TOKEN"]
    chat_id = ENV["TELEGRAM_CRITICAL_CHAT_ID"]
    return :degraded unless bot_token && chat_id

    severity = labels[:severity] || labels["severity"] || "info"
    icon = { "critical" => "🔴", "warning" => "⚠️", "info" => "ℹ️" }.fetch(severity, "ℹ️")
    text = "#{icon} ALERTMANAGER FALLBACK: #{annotations[:summary] || annotations['summary']}"

    uri = URI("https://api.telegram.org/bot#{bot_token}/sendMessage")
    request = Net::HTTP::Post.new(uri, "Content-Type" => "application/x-www-form-urlencoded")
    request.body = URI.encode_www_form(chat_id: chat_id, text: text)

    Net::HTTP.start(uri.hostname, uri.port, use_ssl: true,
                    open_timeout: PUSH_TIMEOUT_SECONDS,
                    read_timeout: 10) { |http| http.request(request) }
    :fallback
  rescue StandardError => e
    Rails.logger.error("AlertmanagerNotifier: fallback Telegram also failed — #{e.class}: #{e.message}")
    :failed
  end

  private_class_method :post_to_alertmanager, :fallback_telegram
end
