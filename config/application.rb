# frozen_string_literal: true

require_relative "boot"

require "rails/all"

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

module Himrate
  class Application < Rails::Application
    # Initialize configuration defaults for originally generated Rails version.
    config.load_defaults 8.1

    # TASK-039 MF-3: SQL schema format required for native PG partitioning.
    # Ruby schema dumper не умеет корректно выражать declarative partitioning
    # (default partitions emit INHERITS syntax, which PG 11+ запрещает для
    # partitioned parents). SQL format через pg_dump корректно handles
    # PARTITION OF syntax. structure.sql regenerated каждый db:migrate.
    config.active_record.schema_format = :sql

    # Please, add to the `ignore` list any other `lib` subdirectories that do
    # not contain `.rb` files, or that should not be reloaded or eager loaded.
    # Common ones are `templates`, `generators`, or `middleware`, for example.
    config.autoload_lib(ignore: %w[assets tasks])

    # TASK-090: `app/middleware/` holds Rack middleware that is loaded via the
    # middleware stack (config/initializers/maintenance_mode.rb), never via a
    # constant reference in app code. Config initializers run BEFORE zeitwerk's
    # `setup_main_autoloader`, so the initializer `require`s the file directly.
    # Tell zeitwerk to ignore the directory so it does not also register an
    # autoload for the (already-loaded) constant — avoids the double-load /
    # stale-reference-on-reload anti-pattern. This is the blessed pattern for
    # app dirs loaded outside autoloading (Rails Autoloading guide,
    # "Ignored Directories").
    Rails.autoloaders.main.ignore("#{config.root}/app/middleware")

    # Configuration for the application, engines, and railties goes here.
    #
    # These settings can be overridden in specific environments using the files
    # in config/environments, which are processed later.
    #
    # config.time_zone = "Central Time (US & Canada)"
    # config.eager_load_paths << Rails.root.join("extras")

    # TASK-014: i18n configuration
    config.i18n.default_locale = :en
    config.i18n.available_locales = %i[en ru]
    config.i18n.fallbacks = true
    config.i18n.load_path += Dir[Rails.root.join("config/locales/**/*.yml")]
  end
end
