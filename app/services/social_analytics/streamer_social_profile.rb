# frozen_string_literal: true

module SocialAnalytics
  # Slice-1 orchestrator (SA-1/SA-2, keyless): a Twitch streamer login → their cross-platform social
  # footprint (auto-discovered from Twitch) + the real Telegram public-audience analysis. Validates the
  # end-to-end value on production data with ZERO credentials (Twitch GQL + Telegram public preview).
  # VK (demographics/geo backbone) + YouTube adapters slot into `platforms` once their creds land.
  #
  # Sidekiq-only (fans out to Twitch::GqlClient + Telegram HTTP). The API serves a worker-warmed cache
  # (mirrors the Grow/Moments on-demand pattern) — never blocks a request thread on external I/O.
  class StreamerSocialProfile
    def self.call(login)
      new(login).call
    end

    def initialize(login)
      @login = login.to_s.strip.downcase
    end

    def call
      return nil if @login.blank?

      socials = TwitchSocials.call(@login)
      {
        login: @login,
        socials: socials, # full footprint (every linked account, incl. display-only discord/rkn)
        platforms: { telegram: analyze_telegram(socials) }.compact # analysed platforms (grows w/ creds)
      }
    end

    private

    def analyze_telegram(socials)
      tg = socials.find { |s| s[:platform] == "telegram" && s[:handle].present? }
      return nil unless tg

      profile = Telegram::PublicProfile.call(tg[:handle])
      base = { handle: tg[:handle], url: tg[:url] }
      return base.merge(available: false) unless profile

      base.merge(
        available: true,
        title: profile[:title],
        subscribers: profile[:subscribers],
        metrics: profile[:metrics],
        recent_posts: profile[:posts].first(20),
        trust: Telegram::TrustScore.call(profile[:metrics])
      )
    end
  end
end
