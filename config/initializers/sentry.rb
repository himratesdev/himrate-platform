# frozen_string_literal: true

# Sentry error tracking + structured telemetry.
#
# DSN-driven configuration: SENTRY_DSN env absent → init still runs but no events
# transmitted (Sentry client behaves as silent no-op). This keeps the gem
# installation safe to land before DSN is provisioned — PVA enrollment + future
# SCW stage breadcrumbs activate the moment DSN is set, no code redeploy needed.
#
# Sample rates intentionally conservative for staging baseline; production tuning
# happens via env after observation period. `enabled_environments` excludes
# `:test` (specs don't ship real events) and `:development` (local dev noise).

return unless defined?(Sentry)

Sentry.init do |config|
  config.dsn = ENV["SENTRY_DSN"]
  config.environment = ENV.fetch("KAMAL_DESTINATION", Rails.env)
  config.release = ENV["GIT_SHA"] || ENV["KAMAL_VERSION"]

  config.enabled_environments = %w[staging production]

  # Breadcrumbs: capture Rails log lines + HTTP outbound + Active Support
  # notifications (which SCW will emit per stage). This is the signal pipeline
  # for telemetry-first diagnostic per
  # `memory/feedback_telemetry_first_diagnostic.md`.
  config.breadcrumbs_logger = %i[active_support_logger http_logger]

  # Performance: enable APM tracing at modest sample rate; bump in production
  # once breadcrumb signal is validated.
  config.traces_sample_rate = ENV.fetch("SENTRY_TRACES_SAMPLE_RATE", "0.05").to_f

  # Profiling currently OFF; revisit after traces baseline established.
  config.profiles_sample_rate = 0.0

  # Don't capture broad Rails 500s twice — Sidekiq integration + rescue blocks
  # already wrap pipeline error paths via explicit `capture_exception` calls.
  config.send_default_pii = false

  # Fingerprinting strategy: per-callsite (default). Tagged callsites in workers
  # / external clients (twitch/gql_client, event_sub_service, irc_monitor, SCW
  # stages) supply their own `fingerprint:` via capture_exception's scope.
end
