# frozen_string_literal: true

require "spec_helper"
ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"

abort("The Rails environment is running in production mode!") if Rails.env.production?
require "rspec/rails"
require "webmock/rspec"

WebMock.disable_net_connect!(allow_localhost: true)

begin
  ActiveRecord::Migration.maintain_test_schema!
rescue ActiveRecord::PendingMigrationError => e
  abort e.to_s.strip
end

# TASK-086: pg_dump dumps materialized views WITH NO DATA, so a test DB loaded from
# db/structure.sql has latest_tih_per_stream in an unpopulated state — querying it
# raises PG::ObjectNotInPrerequisiteState (and aborts the surrounding transaction).
# In production the migration's `CREATE MATERIALIZED VIEW … AS …` defaults to
# WITH DATA, so it's populated there. Populate it once here (committed, before any
# example) so consumers (BestWorstStreamFinder, StreamerReputation.pattern_history,
# CleanupWorker row-stats) and the LatestTihPerStream model are queryable in tests.
begin
  ActiveRecord::Base.connection.execute("REFRESH MATERIALIZED VIEW latest_tih_per_stream")
rescue ActiveRecord::StatementInvalid => e
  warn "rails_helper: could not pre-populate latest_tih_per_stream MV — #{e.class}"
end

# TASK-038: HealthScoreSeeds module lives in db/seeds/ (not autoloaded).
# Specs rely on it for seeding test data — require eagerly to avoid NameError
# when RecommendationTemplate already exists (skipping the conditional load).
require Rails.root.join("db/seeds/health_score.rb")
# BUG-010 PR3: seeds для ML drift forecast confidence thresholds (SignalConfiguration rows)
require Rails.root.join("db/seeds/ml_drift_forecast.rb")

# TASK-039 Phase A3b CR N-4: shared_contexts loader. Additional support files
# can live here (factories shared across multiple specs, common setups, etc.).
Dir[Rails.root.join("spec/support/**/*.rb")].each { |f| require f }

Shoulda::Matchers.configure do |config|
  config.integrate do |with|
    with.test_framework :rspec
    with.library :rails
  end
end

Flipper.configure do |config|
  config.adapter { Flipper::Adapters::Memory.new }
end

RSpec.configure do |config|
  config.fixture_paths = [ Rails.root.join("spec/fixtures") ]
  config.use_transactional_fixtures = true
  config.infer_spec_type_from_file_location!
  config.filter_rails_from_backtrace!
  config.include FactoryBot::Syntax::Methods
  config.include Pundit::Matchers, type: :policy

  config.before(:each) do
    Flipper.features.each(&:remove)
    FlipperDefaults::ALL_FLAGS.each { |flag| Flipper.enable(flag) }
    # TASK-039 FR-040: HOOK_FLAGS registered но НЕ enabled (matchит production
    # initializer behavior — flag готов для future enable без code change).
    # TASK-201 (2026-05-16): :hs_recommendations теперь в HOOK_FLAGS — production
    # initializer no longer auto-enables → Phase 1 migration disable persists.
    # Existing HS endpoint specs that need flag enabled call `Flipper.enable(:hs_recommendations)`
    # explicitly in their `before` block (transitional; Phase 2.5 removes flag + tests).
    FlipperDefaults::HOOK_FLAGS.each_key { |flag| Flipper.add(flag) }
    # CR W-3: isolate Current.signal_config between specs — каждый example
    # стартует с чистым кэшем SignalConfiguration lookups (request/job scoping).
    ActiveSupport::CurrentAttributes.clear_all
  end
end
