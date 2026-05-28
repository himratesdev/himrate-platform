# frozen_string_literal: true

module PersonalAnalytics
  module Export
    # TASK-113 BE-5 (FR-012 / M13 «Экспорт всех моих данных»): собирает ВСЕ PVA-данные пользователя
    # в один Hash для JSON-архивации. Async через ExportWorker → результат хранится в Rails.cache на
    # EXPORT_TTL (24h) → endpoint отдаёт по job_id. ВСЕ pva_* таблицы (rollups/events/chat_activities/
    # tenure/supporter/reflections/patterns/cohort) + privacy_settings + consent_log.
    # Тяжёлые таблицы (view_rollups: до тысяч записей у активного юзера) НЕ paginate — экспорт
    # запускается async (Sidekiq retry 3, MAX_RECORDS_PER_TABLE safety cap для DOS-protection).
    class ExportBuilder
      MAX_RECORDS_PER_TABLE = 50_000 # safety cap: 1y × 365d × ~100 channels = 36500 rollups; 50k=hard limit

      def self.call(user_id)
        new(user_id).call
      end

      def initialize(user_id)
        @user_id = user_id
      end

      def call
        user = User.find_by(id: @user_id)
        return nil unless user

        { schema_version: 1,
          generated_at: Time.current.iso8601,
          user: serialize_user(user),
          analytics: serialize_analytics,
          privacy: serialize_privacy(user) }
      end

      private

      def serialize_user(user)
        { id: user.id, twitch_login: user.username, locale: user.locale,
          role: user.role, created_at: user.created_at.iso8601, deleted_at: user.deleted_at&.iso8601 }
      end

      def serialize_analytics
        { view_rollups: dump(PvaViewRollup), engagement_events: dump(PvaEngagementEvent),
          chat_activities: dump(PvaChatActivity), channel_tenures: dump(ChannelTenure),
          supporter_statuses: dump(PvaSupporterStatus),
          weekly_reflections: dump(PvaWeeklyReflection), patterns: dump(PvaPattern),
          cohort: PvaCohort.where(user_id: @user_id).first&.attributes }
      end

      def serialize_privacy(_user)
        setting = UserPrivacySetting.find_by(user_id: @user_id)
        return { toggles: nil, consent_log: [] } unless setting

        { toggles: setting.slice(*PersonalAnalytics::Api::PrivacyService::DEFAULTS.keys.map(&:to_s)),
          consent_log: setting.consent_log }
      end

      def dump(model)
        model.where(user_id: @user_id).limit(MAX_RECORDS_PER_TABLE).order(created_at: :asc).map(&:attributes)
      end
    end
  end
end
