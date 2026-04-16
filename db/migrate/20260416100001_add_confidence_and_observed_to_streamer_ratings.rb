# frozen_string_literal: true

# TASK-037 FR-010/FR-026: confidence_level + rating_observed for Bayesian transparency.
class AddConfidenceAndObservedToStreamerRatings < ActiveRecord::Migration[8.0]
  def change
    add_column :streamer_ratings, :confidence_level, :string, limit: 20
    add_column :streamer_ratings, :rating_observed, :decimal, precision: 5, scale: 2
  end
end
