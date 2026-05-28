# frozen_string_literal: true

module PersonalAnalytics
  module Api
    # TASK-113 BE-4 (FR-009 / M10): чтение pva_weekly_reflections. Default — последняя строка пользователя
    # (most recent week_start). `?week=YYYY-MM-DD` → конкретная неделя (week_start или ISO-дата внутри
    # недели — Builder нормализует Mon). Archive (`?archive=true`) — список всех week_start пользователя.
    # Edge #6 («неделя без активности»): нет строки для запрошенной недели → 200 с reflection: nil + meta.
    class ReflectionService
      class InvalidWeek < StandardError; end

      ARCHIVE_LIMIT = 52 # год недель

      def initialize(user:, week: nil, archive: nil)
        @user = user
        @week = week
        @archive = ActiveModel::Type::Boolean.new.cast(archive)
      end

      def call
        return archive_payload if @archive

        row = lookup
        return cold_payload if row.nil?

        { data: { reflection: serialize(row) }, meta: meta(cold: false) }
      end

      private

      def serialize(row)
        { week_start: row.week_start.iso8601, narrative: row.narrative, moments: row.moments,
          reflection_source: row.reflection_source, generated_at: row.generated_at.iso8601 }
      end

      def lookup
        scope = PvaWeeklyReflection.where(user_id: @user.id)
        return scope.order(week_start: :desc).first if @week.blank?

        scope.find_by(week_start: parsed_week)
      end

      def parsed_week
        date = Date.iso8601(@week.to_s)
        date - ((date.wday + 6) % 7) # normalize to Monday
      rescue ArgumentError
        raise InvalidWeek, "Invalid week '#{@week}' — expected ISO date YYYY-MM-DD"
      end

      def archive_payload
        weeks = PvaWeeklyReflection.where(user_id: @user.id)
                                   .order(week_start: :desc).limit(ARCHIVE_LIMIT)
                                   .pluck(:week_start, :generated_at)
        { data: { archive: weeks.map { |week_start, generated_at| { week_start: week_start.iso8601,
                                                                    generated_at: generated_at.iso8601 } } },
          meta: meta(cold: weeks.empty?) }
      end

      def cold_payload
        { data: { reflection: nil }, meta: meta(cold: true) }
      end

      def meta(cold:)
        { cold_start: cold, generated_at: Time.current.iso8601 }
      end
    end
  end
end
