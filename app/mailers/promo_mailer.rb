# frozen_string_literal: true

# P7 (3.5): promo-grant confirmation (TASK-H8 Soft Launch invites). Enqueued by
# Promo::RedeemService AFTER the grant transaction commits.
class PromoMailer < ApplicationMailer
  def activated(user, tier:, expires_at:)
    @user = user
    @tier = tier
    @expires_at = expires_at
    I18n.with_locale(user.locale.presence || I18n.default_locale) do
      # Brand plan name, not the raw enum (`premium`) — same key the LK success message uses.
      @tier_name = I18n.t("promo.tiers.#{tier}", default: tier.to_s)
      mail(to: user.email, subject: I18n.t("mailers.promo.activated.subject"))
    end
  end
end
