# frozen_string_literal: true

module Social
  # Harvest social links a channel ANNOUNCES IN ITS OWN CHAT.
  #
  # Why: Twitch only gives us `channel.socialMedias` — the panel links a streamer bothered to fill
  # in. Plenty never do (dear_hellgirl declares only a donation link on Twitch), yet their real
  # Telegram is posted in chat every stream by a mod or an announce-bot. The chat archive we already
  # keep in ClickHouse therefore holds a second, richer footprint source — free, no extra capture.
  #
  # ATTRIBUTION IS THE WHOLE PROBLEM: a link in a channel's chat is not necessarily THAT channel's
  # link (shared chat merges rooms, viewers self-promote, announce-bots quote other channels). A
  # candidate is accepted only with real evidence:
  #   * posted by the broadcaster or a moderator (badges — insiders speak for the channel), OR
  #   * the handle looks like the channel itself (dear_hellgirl ↔ DearHellGirl), OR
  #   * repeated on MIN_DAYS separate days by MIN_POSTERS different accounts (a standing announce).
  # Everything else is left out — a wrong social link is worse than a missing one.
  #
  # Provenance is stored (`source: "chat"`), so a chat-derived link never masquerades as one the
  # streamer declared on Twitch, and the panel sync can always overwrite it.
  class ChatLinkHarvesterWorker
    include Sidekiq::Job
    sidekiq_options queue: :long_running, retry: 1

    WINDOW_DAYS = 30
    MAX_CHANNELS_PER_RUN = 300
    MIN_DAYS = 2       # a one-off paste is not an announcement
    MIN_POSTERS = 2    # …unless an insider posted it (that path bypasses this)
    SOURCE = "chat"

    # host → platform. Only platforms we can name honestly; anything else stays out of the
    # taxonomy (the panel sync already litters it with domains like "oxygendonuts").
    PLATFORMS = {
      "t.me" => "telegram", "telegram.me" => "telegram",
      "youtube.com" => "youtube", "youtu.be" => "youtube",
      "tiktok.com" => "tiktok", "vk.com" => "vk", "vkvideo.ru" => "vk",
      "instagram.com" => "instagram", "boosty.to" => "boosty",
      "discord.gg" => "discord", "discord.com" => "discord"
    }.freeze

    def perform
      rows = candidate_rows
      return if rows.empty?

      by_channel = rows.group_by { |r| r["channel_login"] }
      saved = by_channel.sum { |login, links| persist(login, links) }
      Rails.logger.info("Social::ChatLinkHarvesterWorker: #{saved} links from #{by_channel.size} channels")
    end

    private

    # One ClickHouse pass over the window: every social URL seen in chat with the evidence we need
    # (who posted it, on how many days, whether an insider did).
    def candidate_rows
      Clickhouse::Client.new.select(<<~SQL)
        SELECT channel_login, url,
               uniqExact(toDate(timestamp)) AS days,
               uniqExact(username) AS posters,
               max(insider) AS by_insider,
               count() AS mentions
        FROM (
          SELECT channel_login, username, timestamp,
                 -- badges live in the raw IRC tags; broadcaster/moderator = speaks for the channel
                 (positionCaseInsensitive(raw_tags, 'broadcaster/1') > 0
                  OR positionCaseInsensitive(raw_tags, 'moderator/1') > 0
                  OR user_type = 'mod') AS insider,
                 arrayJoin(extractAll(message_text, '(?i)https?://[a-z0-9./_@-]+')) AS url
          FROM chat_messages
          WHERE timestamp > now() - INTERVAL #{WINDOW_DAYS} DAY
            AND positionCaseInsensitive(message_text, 'http') > 0
        )
        WHERE match(url, '(?i)(t\\\\.me|telegram\\\\.me|youtube\\\\.com|youtu\\\\.be|tiktok\\\\.com|vk\\\\.com|vkvideo\\\\.ru|instagram\\\\.com|boosty\\\\.to|discord\\\\.(gg|com))/')
          AND channel_login IN (SELECT channel_login FROM (
                SELECT channel_login FROM chat_messages
                WHERE timestamp > now() - INTERVAL #{WINDOW_DAYS} DAY
                GROUP BY channel_login ORDER BY count() DESC LIMIT #{MAX_CHANNELS_PER_RUN}))
        GROUP BY channel_login, url
        HAVING mentions >= 2
      SQL
    rescue StandardError => e
      Rails.logger.warn("Social::ChatLinkHarvesterWorker: ClickHouse read failed (#{e.class}) — skip run")
      []
    end

    def persist(login, rows)
      channel = Channel.active.find_by(login: login)
      return 0 unless channel

      accepted = rows.filter_map { |row| normalize(row, login) }.select { |c| trusted?(c, login) }
      return 0 if accepted.empty?

      # One row per (channel, platform, handle); the panel sync owns its own rows — we only ever
      # touch chat-sourced ones, so a streamer's declared link is never overwritten by chat noise.
      accepted.uniq { |c| [ c[:platform], c[:handle] ] }.count do |cand|
        link = ChannelSocialLink.find_or_initialize_by(channel_id: channel.id, url: cand[:url])
        next false if link.persisted? && link.source != SOURCE

        link.assign_attributes(platform: cand[:platform], handle: cand[:handle], source: SOURCE,
                               analyzable: ChannelSocialLink::ANALYZABLE_PLATFORMS.include?(cand[:platform]))
        link.save
      end
    end

    def normalize(row, _login)
      url = row["url"].to_s.sub(%r{\Ahttps?://(www\.)?}, "").chomp("/")
      host, path = url.split("/", 2)
      platform = PLATFORMS[host.to_s.downcase]
      return nil if platform.nil? || path.blank?

      handle = path.split(%r{[/?#]}).first.to_s.delete_prefix("@").delete_prefix("s/")
      return nil if handle.blank? || handle.length > 64

      { platform: platform, handle: handle, url: "https://#{host}/#{path}",
        days: row["days"].to_i, posters: row["posters"].to_i,
        by_insider: row["by_insider"].to_i == 1 }
    end

    # Evidence gate — see the class comment. Handle-resemblance uses the channel login stripped of
    # separators, so "dear_hellgirl" matches "DearHellGirl" but not an unrelated handle.
    def trusted?(candidate, login)
      return true if candidate[:by_insider]

      normalized_login = login.to_s.downcase.delete("_-.")
      normalized_handle = candidate[:handle].downcase.delete("_-.")
      return true if normalized_handle.include?(normalized_login) || normalized_login.include?(normalized_handle)

      candidate[:days] >= MIN_DAYS && candidate[:posters] >= MIN_POSTERS
    end
  end
end
