# frozen_string_literal: true

# P4 CR iter-1 (MF-1): the demand signal is the (email, source, plan) triple, not the address.
# The original UNIQUE(email) made `capture` a no-op for anyone who had already left their email on
# screen 71 — their /pricing plan click returned {subscribed: true} while writing nothing, and a
# visitor clicking Premium then Business kept only the first. Uniqueness now lives at the interest
# level (NULL plan folded via COALESCE — PG treats NULLs as distinct, so a plain composite index
# would let duplicate lk_launch rows through).
class ScopeNotifyRequestUniquenessToInterest < ActiveRecord::Migration[8.0]
  def change
    remove_index :notify_requests, :email, unique: true, name: "index_notify_requests_on_email"
    add_index :notify_requests, "email, source, COALESCE(plan, ''::character varying)",
              unique: true, name: "index_notify_requests_on_interest"
    # Demand read path: "how many asked for plan X" / "which source drove it".
    add_index :notify_requests, %i[source plan], name: "index_notify_requests_on_source_and_plan"
  end
end
