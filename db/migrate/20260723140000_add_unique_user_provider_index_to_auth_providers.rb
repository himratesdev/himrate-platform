# frozen_string_literal: true

# Enforce ONE AuthProvider per (user, provider): a user has at most one twitch / google / youtube
# connection. The existing unique index is only on (provider, provider_id) — it prevents two users
# claiming the same external identity, but nothing stopped a single user accreting duplicate rows of
# the same provider (the YouTube connect-flow's find_or_create races on a double-click). This index is
# the durable fix and makes "which youtube row" unambiguous for the demographics worker (PR-2).
#
# Safe to add: probed staging — 0 existing (user_id, provider) duplicates (login creates exactly one
# provider per user per identity). CONCURRENTLY (no table lock), idempotent.
class AddUniqueUserProviderIndexToAuthProviders < ActiveRecord::Migration[8.0]
  disable_ddl_transaction!

  def up
    add_index :auth_providers, %i[user_id provider], unique: true,
              name: "index_auth_providers_on_user_id_and_provider",
              algorithm: :concurrently, if_not_exists: true
  end

  def down
    remove_index :auth_providers, name: "index_auth_providers_on_user_id_and_provider", if_exists: true
  end
end
