# frozen_string_literal: true

module PersonalAnalytics
  module Account
    # TASK-113 BE-5 (FR-012 / M13 «Удалить аккаунт и данные»): **минимальный** soft-delete (PO directive
    # 2026-05-28: «делит минимальный — все оставляем по пользователю»). Не cascade-уничтожаем PVA-данные;
    # User помечается deleted_at, sessions revoked (logout всех устройств), GDPR consent_log append.
    # Authentication уже учитывает soft-delete: Api::BaseController#authenticate_user! использует
    # `User.active.find(...)` → soft-deleted юзер получает 401 UNAUTHORIZED на любой запрос.
    # Идемпотентно: если deleted_at уже стоит — no-op (consent_log entry НЕ дублируется).
    # Full hard-delete (cascade-PVA-tables) = отдельная задача когда придёт legal-trigger
    # ([[feedback_legal_deferred]] — react-only). Сейчас reversible (PO может откатить deleted_at).
    class DeletionService
      def self.call(user)
        new(user).call
      end

      def initialize(user)
        @user = user
      end

      def call
        return @user if @user.deleted_at.present?

        ActiveRecord::Base.transaction do
          @user.update!(deleted_at: Time.current)
          @user.sessions.destroy_all # revoke refresh tokens (effective logout всех устройств)
          PersonalAnalytics::Privacy::ConsentLogger.log!(@user, action: "account_deleted")
        end
        @user
      end
    end
  end
end
