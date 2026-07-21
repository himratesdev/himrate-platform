# frozen_string_literal: true

# view_sub_ratio decimal(6,1) maxes at 99999.9 — a small-subs/high-views channel (e.g. a brand-new
# channel with 1 subscriber and a viral post) overflows it → PG::NumericValueOutOfRange crashes the
# snapshot write (the T1 numeric-overflow incident pattern). Widen to (9,2). Descriptive «Просматриваемость».
class WidenSocialViewSubRatio < ActiveRecord::Migration[8.0]
  def up
    change_column :social_profile_snapshots, :view_sub_ratio, :decimal, precision: 9, scale: 2
  end

  def down
    change_column :social_profile_snapshots, :view_sub_ratio, :decimal, precision: 6, scale: 1
  end
end
