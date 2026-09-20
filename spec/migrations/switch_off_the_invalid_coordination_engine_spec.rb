# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20260919131000_switch_off_the_invalid_coordination_engine")

# WEB-CONSOLIDATION: the HOOK_FLAGS move only stops the re-enable; this migration clears the ON that
# live staging already holds. The rollback must never switch the invalid engine back on.
RSpec.describe SwitchOffTheInvalidCoordinationEngine, type: :model do
  subject(:migration) { described_class.new }

  before { Flipper.enable(:coordination_engine) } # the state staging Redis holds before the deploy

  it "switches the engine off" do
    migration.up

    expect(Flipper.enabled?(:coordination_engine)).to be false
  end

  it "is idempotent" do
    2.times { migration.up }

    expect(Flipper.enabled?(:coordination_engine)).to be false
  end

  it "does not switch the engine back on when rolled back" do
    migration.up
    migration.down

    expect(Flipper.enabled?(:coordination_engine)).to be false
  end
end
