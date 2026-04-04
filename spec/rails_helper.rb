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
    # Enable all operational flags — mirrors production default.
    # Individual tests disable specific flags as needed.
    %i[
      pundit_authorization bot_raid_chain compare_unlimited audience_overlap
      ad_calculator social_presence panel_tracking tracking_requests
      irc_monitor stream_monitor known_bots channel_discovery
      bot_scoring signal_compute
    ].each { |flag| Flipper.enable(flag) }
  end
end
