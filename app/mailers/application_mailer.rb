# frozen_string_literal: true

class ApplicationMailer < ActionMailer::Base
  # Verified Postmark sender — override via MAIL_FROM env (email-marketing foundation).
  default from: ENV.fetch("MAIL_FROM", "HimRate <noreply@himrate.com>")
  layout "mailer"
end
