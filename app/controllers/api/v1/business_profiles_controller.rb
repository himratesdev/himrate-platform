# frozen_string_literal: true

module Api
  module V1
    # ONBOARD-D0 (screen 72): the user's business-account application (singular resource —
    # one profile per user). GET = current state, PUT = draft upsert (autosave, lenient),
    # POST submit = full validation → pending + PO Telegram alert. Approve/reject stay a
    # PO rails-runner action until the admin panel (TASK-150.8).
    class BusinessProfilesController < Api::BaseController
      before_action :authenticate_user!

      # GET /api/v1/business_profile
      def show
        authorize BusinessProfile, :show?
        render json: { data: serialize(current_user.business_profile) }
      end

      # PUT /api/v1/business_profile — draft upsert (no completeness requirements)
      def update
        authorize BusinessProfile, :update?
        profile = current_user.business_profile || current_user.build_business_profile
        return render_locked(profile) if profile.persisted? && %w[pending approved].include?(profile.status)

        profile.assign_attributes(profile_params)
        profile.status = "draft" if profile.new_record? || profile.status == "rejected"
        if profile.save
          render json: { data: serialize(profile) }
        else
          render_invalid(profile)
        end
      end

      # POST /api/v1/business_profile/submit — full validation → pending + PO alert
      def submit
        authorize BusinessProfile, :submit?
        profile = current_user.business_profile || current_user.build_business_profile
        return render_locked(profile) if profile.persisted? && %w[pending approved].include?(profile.status)

        profile.assign_attributes(profile_params)
        profile.status = "pending"
        if profile.save
          TelegramAlertWorker.perform_async(
            "🏢 Бизнес-заявка: #{profile.company_name} (#{profile.org_type}, ИНН #{profile.inn}) " \
            "· #{current_user.email} · runner: BusinessProfile.find(\"#{profile.id}\").approve!"
          )
          render json: { data: serialize(profile) }, status: :created
        else
          render_invalid(profile)
        end
      end

      private

      def profile_params
        params.permit(:org_type, :company_name, :inn, :website, :sphere, :authority_confirmed)
      end

      def serialize(profile)
        return { status: "none" } unless profile

        profile.slice("org_type", "company_name", "inn", "website", "sphere",
                      "authority_confirmed", "status", "review_note")
               .symbolize_keys
      end

      def render_locked(profile)
        render json: { error: "PROFILE_LOCKED",
                       message: I18n.t("business.errors.locked"),
                       data: serialize(profile) }, status: :conflict
      end

      def render_invalid(profile)
        render json: { error: "VALIDATION_FAILED",
                       message: profile.errors.full_messages.join("; ") }, status: :unprocessable_entity
      end
    end
  end
end
