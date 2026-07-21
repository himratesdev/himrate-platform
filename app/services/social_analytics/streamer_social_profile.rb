# frozen_string_literal: true

module SocialAnalytics
  # Slice-1 orchestrator (SA-1/SA-2, keyless): a Twitch streamer login → their cross-platform social
  # footprint (auto-discovered from Twitch) + DESCRIPTIVE Telegram public analytics. Validates the
  # end-to-end value on production data with ZERO credentials (Twitch GQL + Telegram public preview).
  #
  # NOT a fraud/накрутка verdict (PO 2026-07-21: "мы не анализируем накрутку соц сетей" — bot-detection
  # stays Twitch-only, where per-viewer data exists; socials have no honest signal for it). We surface
  # the same descriptive field set as TGStat/LabelUp — subscribers, reach, viewability, cadence — as
  # neutral numbers, no "real audience"/LQI score. VK (demographics/geo) + YouTube slot in with creds.
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

      # Build-for-scale: no single external source may crash the whole warm. Each fetch degrades to
      # its own empty/unavailable result so the profile always assembles (footprint + whatever analysed).
      socials = safe("TwitchSocials") { TwitchSocials.call(@login) } || []
      {
        login: @login,
        socials: socials, # full footprint (every linked account, incl. display-only discord/rkn)
        platforms: {
          telegram: analyze_telegram(socials),
          youtube: analyze_youtube(socials)
        }.compact # analysed platforms (grows with creds)
      }
    end

    private

    def safe(label)
      yield
    rescue StandardError => e
      Rails.logger.warn("SocialAnalytics::StreamerSocialProfile[#{@login}] #{label}: #{e.class}: #{e.message[0..160]}")
      nil
    end

    def analyze_telegram(socials)
      tg = socials.find { |s| s[:platform] == "telegram" && s[:handle].present? }
      return nil unless tg

      profile = safe("Telegram") { Telegram::PublicProfile.call(tg[:handle]) }
      base = { handle: tg[:handle], url: tg[:url] }
      return base.merge(available: false) unless profile

      base.merge(
        available: true,
        title: profile[:title],
        subscribers: profile[:subscribers],
        metrics: profile[:metrics],
        recent_posts: profile[:posts].first(20)
      )
    end

    def analyze_youtube(socials)
      yt = socials.find { |s| s[:platform] == "youtube" && s[:url].present? }
      return nil unless yt

      profile = safe("Youtube") { Youtube::PublicProfile.call(yt[:url]) }
      base = { handle: yt[:handle], url: yt[:url] }
      return base.merge(available: false) unless profile

      base.merge(
        available: true,
        title: profile[:title],
        subscribers: profile[:subscribers],
        total_views: profile[:total_views],
        video_count: profile[:video_count],
        metrics: profile[:metrics]
        # demographics (age/gender/geo) = later, via owner-OAuth (YouTube Analytics API) — NOT here
      )
    end
  end
end
