# frozen_string_literal: true

module PersonalAnalytics
  module Patterns
    # TASK-113 BE-4 (FR-010 / M11 «Мои паттерны»): rule-based insight-cards из pva_view_rollups
    # (ADR Variant A; sentiment_enabled=false → ML-hook для ONNX rubert-tiny2 позже, БЕЗ переписывания).
    # Атомарная замена: DELETE rule-based (sentiment_enabled=false) + INSERT новые в одной транзакции
    # — preservs будущие sentiment-карты (sentiment_enabled=true). Edge: «паттернов мало» → builder
    # ничего не пишет, endpoint отдаёт empty list.
    # Правила v1 (3 максимум на UI per wireframe Frame 16):
    #   1. rhythm_weekday_evening — пн-вт-ср вечером ≥40% больше чем сб-вс днём (декомпрессия)
    #   2. rhythm_weekend_morning — сб-вс утром ≥50% больше чем будни утром (ритуал)
    #   3. trend growth/decline — last 30d vs prev 30d ≥20%
    # Sentiment + content-flip (games/IRL) — deferred (нужны game-category mapping + ONNX, не v1).
    class PatternsBuilder
      MIN_TOTAL_SECONDS_30D = 3600    # минимум 1ч активности — иначе rule-based не имеют сигнала
      MIN_BUCKET_SECONDS_PER_HOUR = 60 # минимум 60s/час avg в bucket'е чтобы считать non-zero
      RHYTHM_WEEKDAY_EVENING_RATIO = 1.4
      RHYTHM_WEEKEND_MORNING_RATIO = 1.5
      TREND_MIN_DELTA_PCT = 20

      WEEKDAYS_EARLY = [ 1, 2, 3 ].freeze         # Mon-Wed (декомпрессия концентрируется в начале недели)
      WEEKDAYS_ALL = (1..5).to_a.freeze
      WEEKEND_DAYS = [ 0, 6 ].freeze              # Sun, Sat
      MORNING_HOURS = (6..11).freeze
      DAY_HOURS = (12..17).freeze
      EVENING_HOURS = (18..23).freeze

      def self.call(user_id)
        new(user_id).call
      end

      def initialize(user_id)
        @user_id = user_id
      end

      def call
        return if total_seconds_30d < MIN_TOTAL_SECONDS_30D

        I18n.with_locale(user_locale) do
          patterns = [ rhythm_weekday_evening, rhythm_weekend_morning, trend_growth_decline ].compact
          replace_patterns(patterns)
        end
      end

      private

      def replace_patterns(patterns)
        return if patterns.empty?

        now = Time.current
        rows = patterns.map do |pattern|
          pattern.merge(user_id: @user_id, sentiment_enabled: false,
            computed_at: now, created_at: now, updated_at: now)
        end
        PvaPattern.transaction do
          # Сохраняем sentiment-карты (если когда-то ONNX-воркер их напишет) — удаляем только rule-based.
          PvaPattern.where(user_id: @user_id, sentiment_enabled: false).delete_all
          PvaPattern.insert_all!(rows)
        end
      end

      # === Pattern detection ===

      def rhythm_weekday_evening
        weekday_evening = bucket_avg(WEEKDAYS_EARLY, EVENING_HOURS)
        weekend_day = bucket_avg(WEEKEND_DAYS, DAY_HOURS)
        return nil if weekday_evening < MIN_BUCKET_SECONDS_PER_HOUR || weekend_day < MIN_BUCKET_SECONDS_PER_HOUR

        ratio = weekday_evening.to_f / weekend_day
        return nil if ratio < RHYTHM_WEEKDAY_EVENING_RATIO

        pct = ((ratio - 1) * 100).round
        { pattern_type: "rhythm",
          title: I18n.t("pva.patterns.rhythm_weekday_evening.title"),
          body: I18n.t("pva.patterns.rhythm_weekday_evening.body", pct: pct),
          actionable: I18n.t("pva.patterns.rhythm_weekday_evening.actionable"),
          confidence: clamp_confidence(ratio - 1.0) }
      end

      def rhythm_weekend_morning
        weekend_morning = bucket_avg(WEEKEND_DAYS, MORNING_HOURS)
        weekday_morning = bucket_avg(WEEKDAYS_ALL, MORNING_HOURS)
        return nil if weekend_morning < MIN_BUCKET_SECONDS_PER_HOUR ||
                      weekday_morning < MIN_BUCKET_SECONDS_PER_HOUR

        ratio = weekend_morning.to_f / weekday_morning
        return nil if ratio < RHYTHM_WEEKEND_MORNING_RATIO

        start_hour = earliest_active_hour(WEEKEND_DAYS, MORNING_HOURS) || MORNING_HOURS.first
        { pattern_type: "rhythm",
          title: I18n.t("pva.patterns.rhythm_weekend_morning.title"),
          body: I18n.t("pva.patterns.rhythm_weekend_morning.body", start_hour: start_hour),
          actionable: nil,
          confidence: clamp_confidence(ratio - 1.0) }
      end

      def trend_growth_decline
        return nil if prev_30_total.zero? || last_30_total < MIN_TOTAL_SECONDS_30D

        delta_pct = ((last_30_total - prev_30_total).to_f / prev_30_total * 100).round
        return nil if delta_pct.abs < TREND_MIN_DELTA_PCT

        scope = delta_pct.positive? ? "growth_recent" : "decline_recent"
        { pattern_type: "rhythm",
          title: I18n.t("pva.patterns.#{scope}.title"),
          body: I18n.t("pva.patterns.#{scope}.body", delta_pct: delta_pct.abs),
          actionable: nil,
          confidence: clamp_confidence(delta_pct.abs.to_f / 100) }
      end

      # === Data aggregations ===

      # avg seconds-per-(dow,hour)-cell за 30-дневное окно. blocks = |wdays| × |hours|.
      def bucket_avg(wdays, hour_range)
        blocks = wdays.size * hour_range.size
        return 0 if blocks.zero?

        total = hour_dow_matrix.sum do |(wday, hour), secs|
          wdays.include?(wday) && hour_range.cover?(hour) ? secs : 0
        end
        total / blocks
      end

      # Самый ранний час с активностью ≥ MIN_BUCKET_SECONDS_PER_HOUR в bucket'е (для "с %{start_hour}:00").
      def earliest_active_hour(wdays, hour_range)
        per_hour = Hash.new(0)
        hour_dow_matrix.each do |(wday, hour), secs|
          per_hour[hour] += secs if wdays.include?(wday) && hour_range.cover?(hour)
        end
        per_hour.sort.find { |_, secs| secs >= MIN_BUCKET_SECONDS_PER_HOUR * wdays.size }&.first
      end

      def hour_dow_matrix
        return @hour_dow_matrix if defined?(@hour_dow_matrix)

        @hour_dow_matrix = Hash.new(0)
        PvaViewRollup.where(user_id: @user_id, date: 30.days.ago.to_date..Date.current)
                     .pluck(:date, :hour_histogram).each do |date, histogram|
          histogram.each { |hour, secs| @hour_dow_matrix[[ date.wday, hour.to_i ]] += secs }
        end
        @hour_dow_matrix
      end

      def total_seconds_30d
        last_30_total
      end

      def last_30_total
        @last_30_total ||= PvaViewRollup.where(user_id: @user_id,
          date: 30.days.ago.to_date..Date.current).sum(:total_seconds)
      end

      def prev_30_total
        @prev_30_total ||= PvaViewRollup.where(user_id: @user_id,
          date: 60.days.ago.to_date..31.days.ago.to_date).sum(:total_seconds)
      end

      def user_locale
        @user_locale ||= (User.where(id: @user_id).pick(:locale).presence || I18n.default_locale).to_s.to_sym
      end

      def clamp_confidence(value)
        [ value.to_f, 0.99 ].min.clamp(0.0, 0.99).round(2)
      end
    end
  end
end
