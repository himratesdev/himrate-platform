# frozen_string_literal: true

# Single source for transactional-mail delivery wiring (P7 / CR iter-1 Nit-4).
#
# Deliberately NOT an app initializer: `config.action_mailer.*` has to be set while the
# environment file is still being evaluated. Rails' own `action_mailer.set_configs` railtie
# initializer pushes that config onto ActionMailer::Base before any file in config/initializers
# runs, so wiring the provider there would silently do nothing. Both staging.rb and
# production.rb had a byte-identical copy of this block — the drift class that cost us the
# AUTO_TRIGGER_GH_PAT incident — hence one module, three call sites.
module HimRate
  module MailerDelivery
    # Mail jobs ride the existing :notifications queue (deploy.yml compute_tier3 `-q notifications,2`,
    # sidekiq.yml). A dedicated `mailers` queue would need its own consumer for zero gain at this volume.
    QUEUE = :notifications

    # Sets the deliver_later queue everywhere, and wires the Resend provider when a key is present.
    #
    # provider: false — queue name only, never a real provider (test env: a RESEND_API_KEY exported
    # in the shell must not turn `bundle exec rspec` into a live sender).
    #
    # Resend (CO-002: Postmark rejected the Gmail signup; Resend holds the verified himrate.com
    # domain, RESEND_API_KEY in GH secrets). The gem's Railtie registers delivery_method :resend
    # (Resend::Mailer); the key is the gem-global `Resend.api_key` and Resend::Mailer#initialize
    # raises unless it is set — so it must be assigned BEFORE delivery_method (resend-1.13.0).
    #
    # Returns true when the provider was wired, false when only the queue name was set.
    def self.configure(config, env: ENV, provider: true)
      config.action_mailer.deliver_later_queue_name = QUEUE
      api_key = env["RESEND_API_KEY"]
      return false unless provider && api_key.present?

      Resend.api_key = api_key
      config.action_mailer.delivery_method = :resend
      # Raise on failure so a broken send surfaces as a dead job instead of silently dropping.
      config.action_mailer.raise_delivery_errors = true
      config.action_mailer.perform_deliveries = true
      true
    end
  end
end
