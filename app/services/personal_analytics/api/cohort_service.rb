# frozen_string_literal: true

module PersonalAnalytics
  module Api
    # TASK-113 BE-4 (FR-011 / M12): чтение pva_cohort. Один row per user (unique [user_id]); suggestions =
    # jsonb [{login, display_name, pct}]. Edge #7 («когорта появится позже»): нет строки → cold payload.
    class CohortService
      def initialize(user:)
        @user = user
      end

      def call
        row = PvaCohort.find_by(user_id: @user.id)
        return cold_payload if row.nil?

        { data: { suggestions: row.suggestions, cohort_method: row.cohort_method,
                  computed_at: row.computed_at.iso8601 },
          meta: meta(cold: false) }
      end

      private

      def cold_payload
        { data: { suggestions: [], cohort_method: nil, computed_at: nil }, meta: meta(cold: true) }
      end

      def meta(cold:)
        { cold_start: cold, generated_at: Time.current.iso8601 }
      end
    end
  end
end
