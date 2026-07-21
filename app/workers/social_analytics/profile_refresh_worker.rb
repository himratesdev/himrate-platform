# frozen_string_literal: true

module SocialAnalytics
  # Warms a streamer's social profile: fetches the descriptive analytics (StreamerSocialProfile —
  # Twitch GQL + Telegram public, both external → Sidekiq-only), persists a snapshot per platform
  # (building the growth time series), attaches growth deltas from history, and caches the result.
  # On-demand, warmed by the endpoint on a cold miss (Grow/Moments pattern) — zero recurring load.
  #
  # Descriptive only — no fraud/накрутка verdict (PO 2026-07-21).
  class ProfileRefreshWorker
    include Sidekiq::Worker
    sidekiq_options queue: :long_running, retry: 2

    CACHE_TTL = 24.hours
    PENDING_TTL = 10.minutes
    GROWTH_WINDOWS = { "30d" => 30, "90d" => 90, "180d" => 180, "365d" => 365 }.freeze

    def self.cache_key(login) = "social:profile:v1:#{login.to_s.strip.downcase}"
    def self.pending_key(login) = "social:profile:v1:pending:#{login.to_s.strip.downcase}"

    def perform(login)
      login = login.to_s.strip.downcase
      return if login.blank?

      profile = StreamerSocialProfile.call(login)
      return unless profile

      persist_snapshots(login, profile)
      profile = attach_growth(login, profile)
      Rails.cache.write(self.class.cache_key(login),
                        profile.merge(generated_at: Time.current.iso8601), expires_in: CACHE_TTL)
    ensure
      Rails.cache.delete(self.class.pending_key(login))
    end

    private

    def persist_snapshots(login, profile)
      (profile[:platforms] || {}).each do |platform, data|
        next unless data && data[:available]

        m = data[:metrics] || {}
        SocialProfileSnapshot.create!(
          twitch_login: login, platform: platform.to_s, handle: data[:handle],
          captured_at: Time.current, subscribers: data[:subscribers],
          avg_views: m[:avg_views], view_sub_ratio: m[:view_sub_ratio],
          posts_on_page: m[:posts_on_page], metrics: m
        )
      end
    end

    def attach_growth(login, profile)
      grown = (profile[:platforms] || {}).to_h do |platform, data|
        next [ platform, data ] unless data && data[:available]

        [ platform, data.merge(growth: growth_for(login, platform.to_s, data[:subscribers])) ]
      end
      profile.merge(platforms: grown)
    end

    # Subscriber deltas vs the newest snapshot at/older than each window. Empty until history
    # accumulates — honest (we show growth only when we actually have the past datapoint).
    def growth_for(login, platform, current_subs)
      return {} if current_subs.nil?

      GROWTH_WINDOWS.filter_map do |label, days|
        past = SocialProfileSnapshot.for_login(login).on_platform(platform)
                                    .where(captured_at: ..days.days.ago)
                                    .order(captured_at: :desc).first
        next unless past&.subscribers

        delta = current_subs - past.subscribers
        [ label, { delta: delta, pct: past.subscribers.positive? ? (delta.to_f / past.subscribers * 100).round(1) : nil } ]
      end.to_h
    end
  end
end
