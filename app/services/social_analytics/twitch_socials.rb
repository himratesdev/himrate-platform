# frozen_string_literal: true

module SocialAnalytics
  # Cross-platform identity SEED (SA-2). Twitch exposes a streamer's linked socials via GQL
  # `channel.socialMedias` (structured {name,title,url}, keyless via Android Client-ID — verified live
  # 2026-07-21: recrent → vk/youtube/t/discord/gosuslugi). This is the highest-signal auto-discovery:
  # the streamer themselves declared these accounts on their Twitch About panel. We normalise Twitch's
  # platform `name` to our enum + extract the handle so downstream per-platform adapters can analyse.
  #
  # Sidekiq-only (wraps Twitch::GqlClient — retry sleep blocks Puma threads).
  class TwitchSocials
    # Twitch socialMedias `name` → our platform key. РКН/gosuslugi = a registration flag (LabelUp shows it).
    PLATFORM_MAP = {
      "t" => "telegram", "telegram" => "telegram",
      "youtube" => "youtube", "youtube-2" => "youtube",
      "vk" => "vk", "vkontakte" => "vk",
      "instagram" => "instagram", "instagram-2" => "instagram",
      "tiktok" => "tiktok",
      "twitter" => "twitter", "x" => "twitter",
      "discord" => "discord",
      "gosuslugi" => "rkn"
    }.freeze

    # Platforms our adapters can actually analyse (rest = display-only footprint links).
    ANALYZABLE = %w[telegram youtube vk instagram tiktok].freeze

    def self.call(login)
      new(login).call
    end

    def initialize(login)
      @login = login.to_s.strip.downcase
    end

    # → [{ platform:, title:, url:, handle:, analyzable: }] (empty on missing channel / no socials).
    def call
      return [] if @login.blank?

      about = Twitch::GqlClient.new.channel_about(channel_login: @login)
      socials = about && about[:social_medias]
      return [] if socials.blank?

      socials.filter_map { |sm| normalize(sm) }
    end

    private

    def normalize(social)
      raw = social[:name].to_s.downcase
      platform = PLATFORM_MAP[raw] || raw
      url = social[:url].to_s
      {
        platform: platform,
        title: social[:title],
        url: url,
        handle: extract_handle(platform, url),
        analyzable: ANALYZABLE.include?(platform)
      }
    end

    def extract_handle(platform, url)
      case platform
      when "telegram"  then url[%r{t\.me/(?:s/)?([A-Za-z0-9_]+)}, 1]
      when "vk"        then url[%r{vk\.com/([A-Za-z0-9_.]+)}, 1]
      when "youtube"   then url[%r{youtube\.com/(?:@|c/|channel/|user/)?([A-Za-z0-9_.@\-]+)}, 1]
      when "instagram" then url[%r{instagram\.com/([A-Za-z0-9_.]+)}, 1]
      when "tiktok"    then url[%r{tiktok\.com/@?([A-Za-z0-9_.]+)}, 1]
      end
    end
  end
end
