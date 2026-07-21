# frozen_string_literal: true

require "net/http"
require "base64"

# Dynamic Open Graph share image for a channel (/og/c/:login.png). Renders a 1200×630
# PNG card (variant C — минимал): channel avatar + name + neutral tagline + brand. No
# Trust/ERV data on the card by design — it must be understandable to a first-time
# viewer who sees the shared link, and it works for every channel incl. cold-start.
# (TASK-060 Level 2). SVG template → PNG via libvips (needs librsvg + a Cyrillic font).
module Og
  class ChannelCardImage
    WIDTH = 1200
    HEIGHT = 630
    AVATAR = 260
    FONT = "DejaVu Sans" # Debian base has fonts-dejavu-core (Cyrillic-capable)
    AVATAR_TIMEOUT = 3 # seconds — bounded; the whole PNG is CDN-cached so this is rare
    AVATAR_MAX_BYTES = 3 * 1024 * 1024 # 3 MB cap — a Twitch avatar is ~KBs; guards against a memory bomb
    # Avatar host allow-list: profile_image_url comes from Twitch (static-cdn.jtvnw.net),
    # never raw user input — but pin the host so this can never become a blind SSRF.
    AVATAR_HOST_SUFFIX = ".jtvnw.net"
    # Magic-number → MIME (libvips/librsvg embed): cover the formats Twitch CDN serves.
    IMAGE_SIGNATURES = {
      "\x89PNG".b => "image/png",
      "\xFF\xD8\xFF".b => "image/jpeg",
      "GIF8".b => "image/gif",
      "RIFF".b => "image/webp" # RIFF....WEBP; RIFF prefix is sufficient to disambiguate here
    }.freeze

    def initialize(channel)
      @channel = channel
    end

    # Returns PNG binary (String).
    def call
      svg = build_svg
      Vips::Image.new_from_buffer(svg, "", access: :sequential).pngsave_buffer
    end

    private

    def name
      (@channel.display_name.presence || @channel.login).to_s
    end

    def handle
      "@#{@channel.login}"
    end

    # Avatar as an inline data-URI clipped to a circle. Falls back to a coral disc with
    # the channel initial when the image can't be fetched — never blocks the render.
    def avatar_fragment
      data_uri = fetch_avatar_data_uri
      cx = 150 + AVATAR / 2
      cy = HEIGHT / 2
      if data_uri
        <<~SVG
          <clipPath id="c"><circle cx="#{cx}" cy="#{cy}" r="#{AVATAR / 2}"/></clipPath>
          <image x="150" y="#{cy - AVATAR / 2}" width="#{AVATAR}" height="#{AVATAR}"
                 href="#{data_uri}" clip-path="url(#c)" preserveAspectRatio="xMidYMid slice"/>
          <circle cx="#{cx}" cy="#{cy}" r="#{AVATAR / 2}" fill="none" stroke="#FF5C8A" stroke-width="6"/>
        SVG
      else
        initial = xml_escape(name[0, 1].upcase)
        <<~SVG
          <circle cx="#{cx}" cy="#{cy}" r="#{AVATAR / 2}" fill="#FF5C8A"/>
          <text x="#{cx}" y="#{cy}" font-family="#{FONT}" font-size="130" font-weight="700"
                fill="#07070C" text-anchor="middle" dominant-baseline="central">#{initial}</text>
        SVG
      end
    end

    def build_svg
      text_x = 150 + AVATAR + 60
      <<~SVG
        <svg xmlns="http://www.w3.org/2000/svg" width="#{WIDTH}" height="#{HEIGHT}" viewBox="0 0 #{WIDTH} #{HEIGHT}">
          <rect width="#{WIDTH}" height="#{HEIGHT}" fill="#07070C"/>
          <rect width="#{WIDTH}" height="8" fill="#FF5C8A"/>
          <text x="150" y="90" font-family="#{FONT}" font-size="34" font-weight="700" fill="#FF5C8A">HimRate</text>
          #{avatar_fragment}
          <text x="#{text_x}" y="#{HEIGHT / 2 - 30}" font-family="#{FONT}" font-size="64" font-weight="700" fill="#FFFFFF">#{xml_escape(truncate(name, 15))}</text>
          <text x="#{text_x}" y="#{HEIGHT / 2 + 26}" font-family="#{FONT}" font-size="32" fill="#A8A8B4">#{xml_escape(truncate(handle, 20))}</text>
          <text x="#{text_x}" y="#{HEIGHT / 2 + 92}" font-family="#{FONT}" font-size="29" fill="#E7E7EE">Аналитика реальности аудитории Twitch</text>
          <text x="150" y="#{HEIGHT - 60}" font-family="#{FONT}" font-size="28" fill="#7C7C88">himrate.com</text>
        </svg>
      SVG
    end

    def fetch_avatar_data_uri
      url = @channel.profile_image_url.presence
      return nil unless url

      uri = URI.parse(url)
      return nil unless uri.is_a?(URI::HTTPS) && uri.host&.end_with?(AVATAR_HOST_SUFFIX)

      body = nil
      Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: AVATAR_TIMEOUT, read_timeout: AVATAR_TIMEOUT) do |http|
        res = http.get(uri.request_uri)
        return nil unless res.is_a?(Net::HTTPSuccess)
        return nil if res.content_length && res.content_length > AVATAR_MAX_BYTES

        body = res.body
      end
      return nil if body.bytesize > AVATAR_MAX_BYTES # chunked responses lack Content-Length

      mime = mime_for(body)
      return nil unless mime

      "data:#{mime};base64,#{Base64.strict_encode64(body)}"
    rescue StandardError => e
      Rails.logger.warn("[Og::ChannelCardImage] avatar fetch failed for #{@channel.login}: #{e.class}")
      nil
    end

    # MIME by real magic-number signature (not a 3-byte JPEG-or-else guess) — a WebP
    # avatar mislabelled image/png produced an invalid data-URI. Unknown → nil (skip).
    def mime_for(body)
      IMAGE_SIGNATURES.find { |sig, _| body.start_with?(sig) }&.last
    end

    def truncate(str, limit)
      str.length > limit ? "#{str[0, limit - 1]}…" : str
    end

    def xml_escape(str)
      str.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;").gsub('"', "&quot;")
    end
  end
end
