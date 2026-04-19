# frozen_string_literal: true

# TASK-039 ADR §4.14: DB-driven config адаптеров attribution.
# Extensible: future adapters (IGDB, Helix, Twitter, Viral Clip) уже сидированы
# с enabled=false. Включить = UPDATE enabled=true. Без schema changes.

class AttributionSource < ApplicationRecord
  CACHE_KEY = "attribution_sources:known"
  CACHE_TTL = 10.minutes

  validates :source, presence: true, uniqueness: true
  validates :priority, presence: true, numericality: { greater_than_or_equal_to: 0 }
  validates :adapter_class_name, presence: true
  validates :display_label_en, presence: true
  validates :display_label_ru, presence: true

  scope :enabled, -> { where(enabled: true) }
  scope :ordered, -> { order(priority: :asc) }
  scope :pipeline, -> { enabled.ordered }

  # Invalidate cache при любых изменениях — prevents stale validations в AnomalyAttribution.
  after_commit :invalidate_known_sources_cache

  # All source strings (enabled + disabled). Used для AnomalyAttribution.source validation
  # (inclusion check без N+1 — cached 10min per ADR §4.14).
  def self.known_sources
    Rails.cache.fetch(CACHE_KEY, expires_in: CACHE_TTL) { pluck(:source) }
  end

  # Resolves adapter class for runtime dispatch (AnomalyAttributionWorker).
  # Raises if class doesn't exist — explicit failure better than silent skip.
  def adapter_class
    adapter_class_name.constantize
  rescue NameError => e
    raise AdapterNotFound, "Adapter class '#{adapter_class_name}' for source '#{source}' not found: #{e.message}"
  end

  class AdapterNotFound < StandardError; end

  private

  def invalidate_known_sources_cache
    Rails.cache.delete(CACHE_KEY)
  end
end
