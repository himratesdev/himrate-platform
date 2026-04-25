# frozen_string_literal: true

# BUG-012 / CR N-2: UNIQUE index на channels.login built CONCURRENTLY чтобы
# избежать table lock на production scale (100k+ channels). Separate migration —
# CONCURRENTLY requires disable_ddl_transaction!, и cleanup migration
# (20260425100002) runs внутри transaction. Дедуп должен пройти ДО построения
# unique index (otherwise build fails on duplicate values).

class AddUniqueIndexOnChannelsLogin < ActiveRecord::Migration[8.0]
  disable_ddl_transaction!

  def up
    add_index :channels, :login,
      unique: true,
      algorithm: :concurrently,
      if_not_exists: true,
      name: "index_channels_on_login_unique"
  end

  def down
    remove_index :channels,
      name: "index_channels_on_login_unique",
      algorithm: :concurrently,
      if_exists: true
  end
end
