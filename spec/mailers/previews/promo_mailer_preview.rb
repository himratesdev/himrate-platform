# frozen_string_literal: true

class PromoMailerPreview < ActionMailer::Preview
  def activated
    PromoMailer.activated(User.first || FactoryBot.build_stubbed(:user), tier: "premium", expires_at: 14.days.from_now)
  end
end
