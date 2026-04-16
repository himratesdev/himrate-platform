# frozen_string_literal: true

# TASK-038 FR-027: Migrate hs_classification from 4-tier to 5-tier.
# Recomputes classification by stored health_score (not old label).
# Old: excellent (81-100) / good (61-80) / needs_improvement (41-60) / critical (0-40)
# New: excellent (80-100) / good (60-79) / average (40-59) / below_average (20-39) / poor (0-19)

class MigrateHsClassificationTo5Tier < ActiveRecord::Migration[8.0]
  def up
    execute <<~SQL
      UPDATE health_scores SET hs_classification = CASE
        WHEN health_score >= 80 THEN 'excellent'
        WHEN health_score >= 60 THEN 'good'
        WHEN health_score >= 40 THEN 'average'
        WHEN health_score >= 20 THEN 'below_average'
        ELSE 'poor'
      END
      WHERE hs_classification IS NOT NULL;
    SQL

    add_check_constraint :health_scores,
      "hs_classification IN ('excellent','good','average','below_average','poor')",
      name: "hs_classification_5tier"
  end

  def down
    remove_check_constraint :health_scores, name: "hs_classification_5tier"

    execute <<~SQL
      UPDATE health_scores SET hs_classification = CASE
        WHEN health_score >= 81 THEN 'excellent'
        WHEN health_score >= 61 THEN 'good'
        WHEN health_score >= 41 THEN 'needs_improvement'
        ELSE 'critical'
      END
      WHERE hs_classification IS NOT NULL;
    SQL
  end
end
