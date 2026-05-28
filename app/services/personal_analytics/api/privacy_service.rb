# frozen_string_literal: true

module PersonalAnalytics
  module Api
    # TASK-113 BE-5 (FR-014 / M15 «Видимость моей активности»): read `user_privacy_settings`.
    # Возвращает 5 тогглов + полный consent_log (jsonb). Если строки нет — отдаём дефолты
    # (display_name_visible=false, остальные=true; BE-1 миграция/PO decision). НЕ создаёт строку:
    # запись только через UpdateService (на первое PUT). Cold-payload meta.cold_start фиксирует
    # «дефолты, явного согласия не зафиксировано».
    class PrivacyService
      DEFAULTS = {
        display_name_visible: false,
        recognition: true,
        chat_capture: true,
        device_telemetry: true,
        aggregated_stats: true
      }.freeze

      def initialize(user:)
        @user = user
      end

      def call
        setting = UserPrivacySetting.find_by(user_id: @user.id)
        if setting
          { data: { toggles: extract_toggles(setting), consent_log: setting.consent_log },
            meta: meta(cold: false) }
        else
          { data: { toggles: DEFAULTS, consent_log: [] }, meta: meta(cold: true) }
        end
      end

      private

      def extract_toggles(setting)
        DEFAULTS.keys.to_h { |key| [ key, setting.public_send(key) ] }
      end

      def meta(cold:)
        { cold_start: cold, generated_at: Time.current.iso8601 }
      end
    end
  end
end
