# frozen_string_literal: true

module Api
  module V1
    module Me
      # TASK-113 BE-5 (FR-014 / M15 «Видимость моей активности»): privacy toggles + GDPR consent_log.
      # JWT auth + Pundit ownership (свои данные only). За Flipper :pva как остальные PVA-эндпоинты —
      # kill-switch до Frontend Dev. PUT возвращает свежие toggles + лог.
      # Endpoints:
      #   GET    /api/v1/me/privacy → { toggles, consent_log }
      #   PUT    /api/v1/me/privacy { toggles: { display_name_visible: bool, recognition: bool, ... } }
      #   DELETE /api/v1/me → 204 (минимальный soft-delete, PO directive 2026-05-28; M13 FR-012)
      class PrivacyController < Api::BaseController
        before_action :authenticate_user!
        before_action :ensure_pva_enabled

        rescue_from PersonalAnalytics::Privacy::UpdateService::InvalidToggles, with: :render_invalid_params

        # GET /api/v1/me/privacy
        def show
          authorize current_user, :overview?, policy_class: PersonalAnalyticsPolicy
          render json: PersonalAnalytics::Api::PrivacyService.new(user: current_user).call
        end

        # PUT /api/v1/me/privacy
        def update
          authorize current_user, :overview?, policy_class: PersonalAnalyticsPolicy
          toggles = params[:toggles].respond_to?(:to_unsafe_h) ? params[:toggles].to_unsafe_h.to_hash : params[:toggles]
          PersonalAnalytics::Privacy::UpdateService.new(user: current_user, toggles: toggles).call
          render json: PersonalAnalytics::Api::PrivacyService.new(user: current_user).call
        end

        # DELETE /api/v1/me — минимальный soft-delete аккаунта (M13 FR-012 GDPR).
        # PO directive 2026-05-28: НЕ cascade-уничтожаем PVA-данные; User.deleted_at + revoke sessions.
        # Next request → 401 UNAUTHORIZED (authenticate_user! использует User.active).
        def destroy_account
          authorize current_user, :overview?, policy_class: PersonalAnalyticsPolicy
          PersonalAnalytics::Account::DeletionService.call(current_user)
          head :no_content
        end

        private

        def ensure_pva_enabled
          return if Flipper.enabled?(:pva)

          render json: { error: "NOT_FOUND" }, status: :not_found
        end

        def render_invalid_params(exception)
          render json: { error: "INVALID_PARAMS", message: exception.message }, status: :bad_request
        end
      end
    end
  end
end
