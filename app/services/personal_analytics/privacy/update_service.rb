# frozen_string_literal: true

module PersonalAnalytics
  module Privacy
    # TASK-113 BE-5 (FR-014 / M15): запись 5 privacy-тогглов в `user_privacy_settings` + append
    # в `consent_log` (GDPR-аудит). Идемпотентно: если значения не изменились — НЕ дописываем в
    # consent_log (только реальные diff'ы). Concurrency: `create_or_find_by` (Rails 7+ INSERT ON
    # CONFLICT DO NOTHING → SELECT) защищает от расы parallel PUT'ов.
    class UpdateService
      ALLOWED_TOGGLES = %i[display_name_visible recognition chat_capture device_telemetry aggregated_stats].freeze

      class InvalidToggles < StandardError; end

      def initialize(user:, toggles:)
        @user = user
        @toggles = filter(toggles)
      end

      def call
        raise InvalidToggles, "no valid toggles provided" if @toggles.empty?

        setting = find_or_create_setting
        changes = diff(setting, @toggles)
        return setting if changes.empty?

        UserPrivacySetting.transaction do
          setting.update!(@toggles)
          setting.update!(consent_log: setting.consent_log + [ log_entry(changes) ])
        end
        setting
      end

      private

      # Модель имеет `validates :user_id, uniqueness: true`, поэтому Rails-side `create_or_find_by!`
      # падает на SELECT-validator ДО INSERT'а (uniqueness check находит existing → RecordInvalid).
      # Используем: SELECT → CREATE → rescue UNIQUE/Invalid (parallel race) → re-SELECT. Concurrency-safe.
      def find_or_create_setting
        UserPrivacySetting.find_by(user_id: @user.id) ||
          UserPrivacySetting.create!(user_id: @user.id)
      rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid
        UserPrivacySetting.find_by!(user_id: @user.id)
      end

      # Whitelist + cast в boolean (rejects unknown keys, strings → bool). nil-coerced значения
      # отброшены через .compact — чтобы не дёргать update с lit-nil (NOT NULL констрейнты).
      def filter(toggles)
        return {} unless toggles.is_a?(Hash)

        cast = ActiveModel::Type::Boolean.new
        toggles.to_h.symbolize_keys.slice(*ALLOWED_TOGGLES)
               .to_h { |key, value| [ key, cast.cast(value) ] }
               .compact
      end

      def diff(setting, new_toggles)
        new_toggles.each_with_object({}) do |(key, value), acc|
          current = setting.public_send(key)
          acc[key] = { from: current, to: value } if current != value
        end
      end

      def log_entry(changes)
        { action: "toggles_updated", changes: changes, changed_at: Time.current.iso8601 }
      end
    end
  end
end
