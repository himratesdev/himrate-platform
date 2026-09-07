# frozen_string_literal: true

module Net
  # The server sits behind an ISP that interferes with specific hosts — Telegram by IP (blocks that
  # rotate and come back within minutes) and YouTube by DNS (the local resolver simply refuses the
  # name, while the address itself answers fine). Both broke silently: a fetch timed out, the caller
  # logged "platform unavailable", and a whole data source looked empty for weeks.
  #
  # This resolves such hosts over DNS-over-HTTPS (Cloudflare) and caches the answer, so callers can
  # pin a connect IP while TLS/SNI still use the real hostname. Any failure returns nil → the caller
  # falls back to ordinary DNS, which is correct everywhere the block does not exist (CI, dev).
  module BlockedHostResolver
    DOH_URL = "https://1.1.1.1/dns-query"
    CACHE_TTL = 30.minutes
    TIMEOUT = 5

    module_function

    # → "142.250.150.198" | nil
    def resolve(host)
      return nil if host.blank?

      Rails.cache.fetch("doh:a:#{host}", expires_in: CACHE_TTL) { fetch_a_record(host) }
    end

    def fetch_a_record(host)
      uri = URI(DOH_URL)
      uri.query = URI.encode_www_form(name: host, type: "A")
      http = ::Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.open_timeout = TIMEOUT
      http.read_timeout = TIMEOUT

      response = http.request(::Net::HTTP::Get.new(uri, "accept" => "application/dns-json"))
      return nil unless response.is_a?(::Net::HTTPSuccess)

      answers = JSON.parse(response.body).fetch("Answer", [])
      answers.find { |a| a["type"] == 1 }&.fetch("data", nil)
    rescue StandardError => e
      Rails.logger.warn("Net::BlockedHostResolver[#{host}]: #{e.class}: #{e.message&.slice(0, 120)}")
      nil
    end
  end
end
