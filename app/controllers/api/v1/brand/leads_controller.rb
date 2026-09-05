# frozen_string_literal: true

# W1: public B2B lead capture for the /brands contact form. Guest-open (a lead IS anonymous
# by nature); Pundit skipped like the sibling public capture endpoints (tracking_requests /
# lk#notify). Bot defence: the hidden `website` honeypot — a filled value gets a happy 201
# with no record (bots leave satisfied), humans never see the field. Rate: rack_attack
# brand_leads/ip 5/hour.
module Api
  module V1
    module Brand
      class LeadsController < Api::BaseController
        skip_after_action :verify_authorized
        before_action :authenticate_user_optional!

        # POST /api/v1/brand/leads
        def create
          return render(json: { status: "accepted" }, status: :created) if lead_params[:website].present?

          lead = BrandLead.new(lead_params.except(:website).merge(source_page: "/brands"))
          if lead.save
            notify(lead)
            render json: { status: "accepted" }, status: :created
          else
            render json: { error: { code: "VALIDATION_ERROR", details: lead.errors.full_messages } },
                   status: :unprocessable_entity
          end
        end

        private

        def lead_params
          params.permit(:name, :email, :company, :budget, :message, :website)
        end

        # Fire-and-forget: the worker no-ops (warn) while TELEGRAM_* env is absent; the lead is
        # already persisted either way.
        def notify(lead)
          TelegramAlertWorker.perform_async(
            "🟣 <b>Новый B2B-лид</b>\n#{lead.name} · #{lead.email}\n" \
            "#{[ lead.company, lead.budget ].compact.join(' · ')}\n#{lead.message.to_s.truncate(300)}"
          )
        rescue StandardError => e
          Rails.logger.warn("Brand::LeadsController: notify failed — #{e.message}")
        end
      end
    end
  end
end
