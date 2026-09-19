# frozen_string_literal: true

# WEB-CONSOLIDATION: the coordination-rings engine is INVALID — its co-firing bursts turned out to be
# Twitch Shared Chat relays, not coordinated accounts (2026-09-12). Moving :coordination_engine from
# STAGING_ALL_FLAGS to HOOK_FLAGS only stops the boot loop from RE-enabling it: Flipper.add never
# touches an existing flag, and live staging Redis already holds it ON — so after the deploy the
# engine would keep recomputing and the false «группа координации» plaque would keep showing on
# public cards. This clears the existing ON once (db:prepare runs it on web boot).
#
# `down` is a deliberate no-op: rolling back the schema must not switch an invalid engine back on.
# Re-enabling it is a human act, and only for a re-validated engine:
#   bin/rails runner 'Flipper.enable(:coordination_engine)'
class SwitchOffTheInvalidCoordinationEngine < ActiveRecord::Migration[8.0]
  def up
    Flipper.disable(:coordination_engine)
  end

  def down
    # no-op — see the header.
  end
end
