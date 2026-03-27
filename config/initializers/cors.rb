# frozen_string_literal: true

# TASK-015: CORS configuration for Chrome Extension
# Whitelist: chrome-extension://EXTENSION_ID + future web origins
# NEVER use wildcard (*) — CLAUDE.md §Security
#
# Origins evaluated per-request (not at boot) so ENV changes take effect
# without restart. Supports comma-separated ALLOWED_EXTENSION_ID for
# multiple Extension IDs (dev + production).

Rails.application.config.middleware.insert_before 0, Rack::Cors do
  allow do
    origins do |source, _env|
      extension_ids = ENV.fetch("ALLOWED_EXTENSION_ID", "").split(",").map(&:strip).reject(&:empty?)
      extension_origins = extension_ids.map { |id| "chrome-extension://#{id}" }
      web_origins = [ ENV["CORS_ALLOWED_ORIGIN"] ].compact.reject(&:empty?)
      all_origins = extension_origins + web_origins

      all_origins.include?(source)
    end

    resource "/api/*",
      headers: :any,
      methods: %i[get post put patch delete options head],
      credentials: true,
      max_age: 86_400
  end
end
