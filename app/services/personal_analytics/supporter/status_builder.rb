# frozen_string_literal: true

module PersonalAnalytics
  module Supporter
    # TASK-113 BE-3 (FR-008 / M9 «Моё место у каналов»): пересчёт АБСОЛЮТНОГО категориального статуса
    # сапортёра per канал. Формула ADR OQ-1 (стартовые веса, tunable на реальных данных):
    #   composite = tenure_mo·2 + cheers_usd + hype_count·3 + watch_consistency·0.5
    #   ladder: ≥40 devoted / ≥20 loyal / ≥8 regular / else active (candidate = есть engagement/tenure).
    # НЕ числовой публичный скор (BR-006) — composite_score internal-only (маппинг в tier, не в UI).
    # Идемпотентно: полный пересчёт → upsert_all (update_only исключает created_at → не дрейфует).
    # Источники: pva_engagement_events (cheers bits / hype count) + channel_tenure (months) +
    # pva_view_rollups (watch-consistency = distinct days за окно). twitch_channel_id = стабильный ключ.
    class StatusBuilder
      WATCH_WINDOW_DAYS = 90
      BITS_PER_USD = 100.0
      THRESHOLDS = [ [ 40, "devoted" ], [ 20, "loyal" ], [ 8, "regular" ] ].freeze

      def self.call(user_id)
        new(user_id).call
      end

      def initialize(user_id)
        @user_id = user_id
      end

      def call
        logins = candidate_logins
        return if logins.empty?

        rows = build_rows(logins)
        # update_only исключает created_at (не дрейфует на recompute); updated_at Rails обновляет
        # автоматически (не указывать — иначе duplicate assignment).
        PvaSupporterStatus.upsert_all(
          rows, unique_by: %i[user_id twitch_channel_id],
                update_only: %i[channel_id twitch_login tier composite_score computed_at]
        )
      end

      private

      def build_rows(logins)
        enrichment = ChannelEnrichment.resolve(logins.keys)
        cheers = cheer_bits_by_channel
        hypes = hype_count_by_channel
        tenures = tenure_months_by_channel
        watch = watch_days_by_channel
        now = Time.current
        logins.map { |tcid, login| row(tcid, login, enrichment, cheers, hypes, tenures, watch, now) }
      end

      def row(tcid, login, enrichment, cheers, hypes, tenures, watch, now)
        score = composite(tenures[tcid].to_i, cheers[tcid].to_i, hypes[tcid].to_i, watch[tcid].to_i)
        { user_id: @user_id, twitch_channel_id: tcid, channel_id: enrichment[tcid]&.first,
          twitch_login: enrichment[tcid]&.last || login, tier: tier_for(score),
          composite_score: score.round(2), computed_at: now, created_at: now, updated_at: now }
      end

      def composite(tenure_mo, cheer_bits, hype_count, watch_days)
        (tenure_mo * 2) + (cheer_bits / BITS_PER_USD) + (hype_count * 3) + (watch_days * 0.5)
      end

      def tier_for(score)
        THRESHOLDS.each { |threshold, tier| return tier if score >= threshold }
        "active" # candidate = есть engagement/tenure → минимум active
      end

      # {twitch_channel_id => twitch_login} из engagement + tenure (eng wins — свежее).
      def candidate_logins
        tenure = ChannelTenure.where(user_id: @user_id).group(:twitch_channel_id).maximum(:twitch_login)
        engagement = PvaEngagementEvent.where(user_id: @user_id).group(:twitch_channel_id).maximum(:twitch_login)
        tenure.merge(engagement)
      end

      def cheer_bits_by_channel
        PvaEngagementEvent.where(user_id: @user_id, event_type: "cheer").group(:twitch_channel_id).sum(:amount)
      end

      def hype_count_by_channel
        PvaEngagementEvent.where(user_id: @user_id, event_type: "hype_contribution").group(:twitch_channel_id).count
      end

      def tenure_months_by_channel
        ChannelTenure.where(user_id: @user_id).group(:twitch_channel_id).maximum(:months)
      end

      # watch-consistency = distinct дни просмотра за окно (из pva_view_rollups).
      def watch_days_by_channel
        PvaViewRollup.where(user_id: @user_id, date: WATCH_WINDOW_DAYS.days.ago.to_date..Date.current)
                     .group(:twitch_channel_id).distinct.count(:date)
      end
    end
  end
end
