# frozen_string_literal: true

module PersonalAnalytics
  module Cohort
    # TASK-113 BE-4 (FR-011 / M12 «Похожие зрители»): анонимная когорта на основе co-watch overlap по
    # существующей `cross_channel_presences` (Signal #8, indexed UNIQUE [username, channel_id]).
    # ADR Variant A: `cohort_method='co_watch'` → ML-upgrade `cohort_method='embedding'` (Channel2Vec +
    # Faiss) позже БЕЗ переписывания схемы.
    # Алгоритм v1:
    #   1) user_channels  = каналы где появлялся twitch-login юзера
    #   2) peers          = OTHER usernames из тех же каналов (anonymous — login не публикуется)
    #   3) candidates     = каналы где появлялись peers, НЕ пересекающиеся с user_channels
    #   4) pct = peer-count-в-канале / peers.size * 100; фильтр ≥ MIN_PCT; топ MAX_SUGGESTIONS
    # Edge #7 (SRS §3): peers < MIN_PEER_COUNT ИЛИ user_channels < MIN_USER_CHANNELS → builder
    # ничего не пишет (endpoint отдаст «когорта появится позже»).
    # Identity: username берётся из `User.username` ТОЛЬКО для юзеров с активным Twitch OAuth provider —
    # TwitchOauth.find_or_create_user устанавливает username из `twitch_user[:login]` (verify
    # 20260324000003 + auth/twitch_oauth.rb:92). Google-only юзеры → no-op.
    class CohortBuilder
      MIN_USER_CHANNELS = 2
      MIN_PEER_COUNT = 5
      MIN_PCT = 10
      MAX_SUGGESTIONS = 5
      OVERFETCH_MULTIPLIER = 4 # запрос → MAX × N, потом фильтр pct ≥ MIN_PCT, отрезаем по MAX

      def self.call(user_id)
        new(user_id).call
      end

      def initialize(user_id)
        @user_id = user_id
      end

      def call
        return unless twitch_login.present?
        return if user_channel_ids.size < MIN_USER_CHANNELS

        peers = peer_usernames
        return if peers.size < MIN_PEER_COUNT

        suggestions = compute_suggestions(peers)
        return if suggestions.empty?

        upsert(suggestions)
      end

      private

      def twitch_login
        return @twitch_login if defined?(@twitch_login)

        @twitch_login = if user&.auth_providers&.exists?(provider: "twitch")
                          user.username.to_s.downcase.presence
        end
      end

      def user
        @user ||= User.includes(:auth_providers).find_by(id: @user_id)
      end

      def user_channel_ids
        @user_channel_ids ||= CrossChannelPresence.where(username: twitch_login)
                                                  .distinct.pluck(:channel_id)
      end

      def peer_usernames
        @peer_usernames ||= CrossChannelPresence
                            .where(channel_id: user_channel_ids)
                            .where.not(username: twitch_login)
                            .distinct.pluck(:username)
      end

      # Возвращает [{login, display_name, pct}] в порядке pct DESC, capped MAX_SUGGESTIONS.
      def compute_suggestions(peers)
        rows = CrossChannelPresence
               .where(username: peers)
               .where.not(channel_id: user_channel_ids)
               .group(:channel_id)
               .order(Arel.sql("COUNT(DISTINCT username) DESC"))
               .limit(MAX_SUGGESTIONS * OVERFETCH_MULTIPLIER)
               .pluck(:channel_id, Arel.sql("COUNT(DISTINCT username)"))

        ranked = rank_by_pct(rows, peers.size)
        return [] if ranked.empty?

        channels = Channel.where(id: ranked.map { |r| r[:channel_id] }).index_by(&:id)
        ranked.filter_map do |entry|
          channel = channels[entry[:channel_id]]
          next unless channel

          { login: channel.login,
            display_name: channel.display_name.presence || channel.login,
            pct: entry[:pct] }
        end
      end

      def rank_by_pct(rows, peer_count)
        rows.filter_map do |channel_id, count|
          pct = (count.to_f / peer_count * 100).round
          next if pct < MIN_PCT

          { channel_id: channel_id, pct: pct }
        end.first(MAX_SUGGESTIONS)
      end

      def upsert(suggestions)
        now = Time.current
        PvaCohort.upsert_all(
          [ { user_id: @user_id, suggestions: suggestions, cohort_method: "co_watch",
              computed_at: now, created_at: now, updated_at: now } ],
          unique_by: %i[user_id],
          update_only: %i[suggestions cohort_method computed_at]
        )
      end
    end
  end
end
