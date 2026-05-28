# frozen_string_literal: true

module PersonalAnalytics
  module Reflection
    # TASK-113 BE-4 (FR-009 / M10 «Моё резюме недели»): template-нарратив из агрегатов одной недели
    # (Mon-Sun) пользователя. ADR Variant A: `reflection_source='template'` (v1, без ML) → ML-upgrade
    # `reflection_source='llm'` позже БЕЗ переписывания схемы. Идемпотентно: upsert unique
    # [user_id, week_start] (update_only исключает created_at — не дрейфует на recompute).
    # Edge #6 (SRS §3): неделя без активности (total_seconds == 0) → builder возвращает nil,
    # никакая строка не пишется (endpoint отдаст «резюме на след. неделе»).
    # Источники: pva_view_rollups (часы / топ / новые / heatmap-пик) + pva_engagement_events (hype) +
    # channel_tenure (sub-anniversary). Локаль — `user.locale` (en/ru), narrative composed под неё.
    class ReflectionBuilder
      MORNING_HOURS = (6..11).freeze
      DAY_HOURS = (12..17).freeze
      EVENING_HOURS = (18..23).freeze
      WEEKDAY_KEYS = %w[sun mon tue wed thu fri sat].freeze # Date#wday: 0=Sun..6=Sat
      MOMENTS_LIMIT = 5
      HYPE_AVG_LOOKBACK_DAYS = 90

      def self.call(user_id, week_start: nil)
        new(user_id, week_start).call
      end

      def initialize(user_id, week_start)
        @user_id = user_id
        @week_start = normalize_to_monday(week_start || self.class.default_week_start)
        @week_end = @week_start + 6
      end

      # Default = последняя ПОЛНОСТЬЮ завершённая ISO-неделя (Пн..Вс ДО сегодняшнего дня). Воркер
      # запускается понедельником → today.wday=1 → days_back=7 → прошлый Пн (неделя только что
      # закончилась). Единая формула для всех wday (без spec-кейса для воскресенья — semantically
      # «week ending strictly before today», CR nit-1 cosmetic-fix).
      def self.default_week_start
        today = Date.current
        Date.current - ((today.wday + 6) % 7 + 7)
      end

      def call
        return nil if week_source.total_seconds.zero?

        I18n.with_locale(user_locale) do
          row = build_row
          PvaWeeklyReflection.upsert_all(
            [ row ], unique_by: %i[user_id week_start],
                     update_only: %i[narrative moments reflection_source generated_at]
          )
          row
        end
      end

      private

      def build_row
        now = Time.current
        { user_id: @user_id, week_start: @week_start, narrative: compose_narrative,
          moments: compose_moments, reflection_source: "template", generated_at: now,
          created_at: now, updated_at: now }
      end

      # === Narrative composition ===

      def compose_narrative
        parts = [ sentence_total ]
        parts << sentence_top if top_channel
        parts << sentence_new_channels if new_channels_this_week.any?
        parts << sentence_peak if peak_bucket
        parts.compact.join(" ")
      end

      def sentence_total
        delta_clause = format_delta_clause
        I18n.t("pva.reflection.narrative.total",
          hours_minutes: format_hm(week_source.total_seconds), delta_clause: delta_clause)
      end

      def format_delta_clause
        delta = week_source.total_seconds - prev_week_source.total_seconds
        return "" if delta.zero? || prev_week_source.total_seconds.zero?

        key = delta.positive? ? "pva.reflection.narrative.delta_more" : "pva.reflection.narrative.delta_less"
        I18n.t(key, amount: format_hm(delta.abs))
      end

      def sentence_top
        I18n.t("pva.reflection.narrative.top_streamer",
          login: top_channel[:twitch_login] || "—",
          hours_minutes: format_hm(top_channel[:seconds]),
          sessions: RussianPlural.translate("pva.sessions_form", count: top_channel[:sessions]))
      end

      def sentence_new_channels
        I18n.t("pva.reflection.narrative.new_channels",
          channels: RussianPlural.translate("pva.new_channels_form", count: new_channels_this_week.size))
      end

      def sentence_peak
        wday, hour = peak_bucket
        period_key = case hour
        when MORNING_HOURS then "morning"
        when DAY_HOURS then "day"
        when EVENING_HOURS then "evening"
        else "night"
        end
        I18n.t("pva.reflection.narrative.peak",
          period: I18n.t("pva.reflection.peak_period.#{period_key}"),
          weekday: I18n.t("pva.reflection.weekday_genitive.#{WEEKDAY_KEYS[wday]}"))
      end

      # === Moments composition (jsonb [{icon, text}], capped MOMENTS_LIMIT) ===

      def compose_moments
        candidates = anniversary_moments + new_channel_moments + hype_moments
        candidates.first(MOMENTS_LIMIT)
      end

      def anniversary_moments
        ChannelTenure.where(user_id: @user_id, anniversary_at: @week_start..@week_end)
                     .order(:anniversary_at).map do |tenure|
          { icon: "cake", text: I18n.t("pva.reflection.moments.anniversary",
            date: format_anniversary_date(tenure.anniversary_at),
            months_form: RussianPlural.translate("pva.months_form", count: tenure.months.to_i),
            login: tenure.twitch_login) }
        end
      end

      # rails-i18n gem не установлен → RU month names недоступны через I18n.l. Inline-маппинг
      # (RU genitive «21 мая», не nominative «21 май»; EN strftime «May 21»).
      RU_MONTHS_GENITIVE = %w[~ января февраля марта апреля мая июня июля августа сентября октября
        ноября декабря].freeze
      def format_anniversary_date(date)
        return date.strftime("%-d %b") unless I18n.locale == :ru

        "#{date.day} #{RU_MONTHS_GENITIVE[date.month]}"
      end

      def new_channel_moments
        new_channels_this_week.map do |channel|
          visits = channel[:sessions].to_i
          if visits >= 2
            { icon: "rocket", text: I18n.t("pva.reflection.moments.new_channel_repeat",
              login: channel[:twitch_login],
              visits: RussianPlural.translate("pva.visits_form", count: visits)) }
          else
            { icon: "rocket", text: I18n.t("pva.reflection.moments.new_channel_once",
              login: channel[:twitch_login]) }
          end
        end
      end

      def hype_moments
        hype_events.map do |event|
          { icon: "trophy", text: I18n.t("pva.reflection.moments.hype_train",
            login: event.twitch_login || "—",
            pct: hype_pct(event)) }
        end
      end

      def hype_pct(event)
        baseline = hype_baseline_for(event.twitch_channel_id)
        return 100 if baseline.zero? || event.amount.to_i.zero?

        ((event.amount.to_f / baseline) * 100).round
      end

      # Среднее .amount по hype_contribution за HYPE_AVG_LOOKBACK_DAYS у этого канала. Свои события
      # ИСКЛЮЧАЕМ — «287% от среднего» = от typical OTHER viewer's contribution (semantically «насколько
      # больше других»). Иначе baseline тянется самим юзером и pct схлопывается к ~100%.
      def hype_baseline_for(twitch_channel_id)
        @hype_baseline ||= PvaEngagementEvent
                           .where(event_type: "hype_contribution",
                             occurred_at: HYPE_AVG_LOOKBACK_DAYS.days.ago..)
                           .where.not(user_id: @user_id)
                           .group(:twitch_channel_id).average(:amount)
        @hype_baseline[twitch_channel_id].to_f
      end

      # === Data sources ===

      def week_source
        @week_source ||= PersonalAnalytics::Aggregates::ViewRollupSource.new(@user_id, @week_start, @week_end)
      end

      def prev_week_source
        @prev_week_source ||=
          PersonalAnalytics::Aggregates::ViewRollupSource.new(@user_id, @week_start - 7, @week_start - 1)
      end

      def top_channel
        @top_channel ||= week_source.top_channels(1).first
      end

      # Каналы с MIN(date) внутри этой недели по всей истории (НЕ только в окне). `date` — Date-колонка,
      # сравнение TZ-agnostic (first_seen_at — datetime, может мис-матчиться через Time.zone границы).
      # Возвращает [{twitch_channel_id, twitch_login, sessions}] (sessions = за эту неделю).
      def new_channels_this_week
        @new_channels_this_week ||= begin
          new_tcids = PvaViewRollup.where(user_id: @user_id)
                                   .group(:twitch_channel_id)
                                   .having("MIN(date) >= ? AND MIN(date) <= ?", @week_start, @week_end)
                                   .pluck(:twitch_channel_id)
          rows = PvaViewRollup.where(user_id: @user_id, twitch_channel_id: new_tcids,
            date: @week_start..@week_end)
                              .group(:twitch_channel_id)
                              .pluck(:twitch_channel_id, Arel.sql("MAX(twitch_login)"),
                                Arel.sql("SUM(session_count)"))
          rows.map { |tcid, login, sessions| { twitch_channel_id: tcid, twitch_login: login, sessions: sessions.to_i } }
        end
      end

      # peak = (wday, hour) с максимальным total_seconds внутри недели (из hour_histogram per day).
      def peak_bucket
        return @peak_bucket if defined?(@peak_bucket)

        buckets = Hash.new(0)
        PvaViewRollup.where(user_id: @user_id, date: @week_start..@week_end)
                     .pluck(:date, :hour_histogram).each do |date, histogram|
          histogram.each { |hour, seconds| buckets[[ date.wday, hour.to_i ]] += seconds }
        end
        @peak_bucket = buckets.max_by { |_, secs| secs }&.first
      end

      def hype_events
        @hype_events ||= PvaEngagementEvent.where(user_id: @user_id, event_type: "hype_contribution",
          occurred_at: @week_start.beginning_of_day..@week_end.end_of_day).order(occurred_at: :desc).to_a
      end

      def user_locale
        @user_locale ||= (User.where(id: @user_id).pick(:locale).presence || I18n.default_locale).to_s.to_sym
      end

      # Нормализация: любая дата → понедельник той же ISO-недели.
      def normalize_to_monday(date)
        date - ((date.wday + 6) % 7)
      end

      def format_hm(seconds)
        seconds = seconds.to_i.abs
        h = seconds / 3600
        m = (seconds % 3600) / 60
        if h.positive? && m.positive?
          I18n.t("pva.hours_minutes.h_m", h: h, m: m)
        elsif h.positive?
          I18n.t("pva.hours_minutes.h", h: h)
        else
          I18n.t("pva.hours_minutes.m", m: m)
        end
      end
    end
  end
end
