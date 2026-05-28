# frozen_string_literal: true

module PersonalAnalytics
  module Privacy
    # TASK-113 BE-5 (FR-012 / M13 export+delete, M15 privacy): GDPR consent_log append helper.
    # Используется ExportWorker / DeletionService для записи аудит-события (export_completed /
    # account_deleted). find_or_create + rescue race (mirror UpdateService — model имеет Rails-side
    # uniqueness validator на user_id). UpdateService остаётся self-contained для toggle-diff'ов
    # (там логика сложнее — diff between current/new — здесь только append).
    module ConsentLogger
      def self.log!(user, action:, **extra)
        setting = find_or_create_setting(user)
        entry = build_entry(action, extra)
        setting.update!(consent_log: setting.consent_log + [ entry ])
      end

      def self.find_or_create_setting(user)
        UserPrivacySetting.find_by(user_id: user.id) || UserPrivacySetting.create!(user_id: user.id)
      rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid
        UserPrivacySetting.find_by!(user_id: user.id)
      end

      def self.build_entry(action, extra)
        { "action" => action.to_s, "at" => Time.current.iso8601 }.merge(extra.transform_keys(&:to_s))
      end
    end
  end
end
