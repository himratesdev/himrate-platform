# frozen_string_literal: true

# TASK-039 Phase B1b CR N-1: split RaidAdapter → RaidOrganicAdapter + RaidBotAdapter
# для 1:1 source-adapter mapping per ADR §4.14. Existing seed (migration
# 20260419100007) had оба raid_organic + raid_bot sources pointing к shared
# "Trends::Attribution::RaidAdapter" — caused Pipeline redundant invocation.

class SplitRaidAdapterClassNames < ActiveRecord::Migration[8.0]
  def up
    AttributionSource.where(source: "raid_organic")
      .update_all(adapter_class_name: "Trends::Attribution::RaidOrganicAdapter")
    AttributionSource.where(source: "raid_bot")
      .update_all(adapter_class_name: "Trends::Attribution::RaidBotAdapter")
  end

  def down
    AttributionSource.where(source: %w[raid_organic raid_bot])
      .update_all(adapter_class_name: "Trends::Attribution::RaidAdapter")
  end
end
