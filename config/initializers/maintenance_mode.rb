# frozen_string_literal: true

# TASK-090 OQ-4: insert MaintenanceMode middleware BEFORE Rack::Attack so blocked
# requests do not count toward rate-limit buckets.
#
# Config initializers run before zeitwerk's `setup_main_autoloader`, so the
# `MaintenanceMode` constant is not autoloadable here yet — and Rails 8 does not
# constantize a String middleware argument. We therefore `require` the file
# directly; `app/middleware/` is excluded from zeitwerk in config/application.rb,
# so there is no double-load or stale-reference-on-reload.
require Rails.root.join("app/middleware/maintenance_mode")

Rails.application.config.middleware.insert_before Rack::Attack, MaintenanceMode
