# frozen_string_literal: true

module PersonalAnalytics
  module Api
    # TASK-113 BE-4 (FR-010 / M11): чтение pva_patterns. Возвращает все актуальные карты пользователя
    # (rule-based + потенциально sentiment когда ML-таск их добавит) в порядке computed_at DESC.
    # Edge «паттернов мало»: empty list → frontend показывает empty-state.
    class PatternsService
      def initialize(user:)
        @user = user
      end

      def call
        patterns = PvaPattern.where(user_id: @user.id).order(computed_at: :desc, id: :desc).to_a
        { data: { patterns: patterns.map { |pattern| serialize(pattern) } },
          meta: meta(cold: patterns.empty?) }
      end

      private

      def serialize(pattern)
        { id: pattern.id, pattern_type: pattern.pattern_type, title: pattern.title,
          body: pattern.body, actionable: pattern.actionable,
          confidence: pattern.confidence&.to_f, sentiment_enabled: pattern.sentiment_enabled,
          computed_at: pattern.computed_at.iso8601 }
      end

      def meta(cold:)
        { cold_start: cold, generated_at: Time.current.iso8601 }
      end
    end
  end
end
