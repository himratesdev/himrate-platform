# frozen_string_literal: true

# TASK-038 AR-10: Aliases for Twitch game_name variants (e.g., "GTA V" → grand_theft_auto_v).

class HealthScoreCategoryAlias < ApplicationRecord
  belongs_to :health_score_category

  validates :game_name_alias, presence: true, uniqueness: true
end
