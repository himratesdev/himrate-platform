# frozen_string_literal: true

# TASK-039 ADR §4.14: DB-driven config адаптеров attribution.
# Extensible: future adapters (IGDB, Helix, Twitter, Viral Clip) уже сидированы
# с enabled=false. Включить = UPDATE enabled=true. Без schema changes.

class AttributionSource < ApplicationRecord
  validates :source, presence: true, uniqueness: true
  validates :priority, presence: true, numericality: { greater_than_or_equal_to: 0 }
  validates :adapter_class_name, presence: true
  validates :display_label_en, presence: true
  validates :display_label_ru, presence: true

  scope :enabled, -> { where(enabled: true) }
  scope :ordered, -> { order(priority: :asc) }
  scope :pipeline, -> { enabled.ordered }

  # Resolves adapter class for runtime dispatch (AnomalyAttributionWorker).
  # Raises if class doesn't exist — explicit failure better than silent skip.
  def adapter_class
    adapter_class_name.constantize
  rescue NameError => e
    raise AdapterNotFound, "Adapter class '#{adapter_class_name}' for source '#{source}' not found: #{e.message}"
  end

  class AdapterNotFound < StandardError; end
end
