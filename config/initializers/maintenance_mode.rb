# frozen_string_literal: true

# TASK-090 OQ-4: insert MaintenanceMode middleware BEFORE Rack::Attack so blocked
# requests do not count toward rate-limit buckets. Both middlewares live near the
# end of the stack; ordering is enforced explicitly here rather than relying on
# `app/middleware/` autoload order (which is undefined w.r.t. existing inserts).
#
# Note: `app/middleware/` is autoloaded by Rails 8 zeitwerk by default; we still
# require the file eagerly here to be resilient against initializer ordering
# during early boot (middleware stack is frozen before lazy loading completes).
require_relative Rails.root.join("app/middleware/maintenance_mode")

Rails.application.config.middleware.insert_before Rack::Attack, MaintenanceMode
