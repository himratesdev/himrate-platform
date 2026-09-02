# frozen_string_literal: true

class ApplicationMailer < ActionMailer::Base
  # Verified Resend sender (domain himrate.com) — override via MAIL_FROM env.
  default from: ENV.fetch("MAIL_FROM", "HimRate <noreply@himrate.com>")
  layout "mailer"
end
