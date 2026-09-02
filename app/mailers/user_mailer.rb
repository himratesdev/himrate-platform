# frozen_string_literal: true

# P7 (3.5): first real transactional mail. Locale = the user's stored preference
# (users.locale, en|ru) with the app default as fallback; subject + body resolve
# through config/locales/mailers.{en,ru}.yml.
class UserMailer < ApplicationMailer
  def welcome(user)
    @user = user
    I18n.with_locale(user.locale.presence || I18n.default_locale) do
      mail(to: user.email, subject: I18n.t("mailers.user.welcome.subject"))
    end
  end
end
