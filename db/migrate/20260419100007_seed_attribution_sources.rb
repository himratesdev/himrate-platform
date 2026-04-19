# frozen_string_literal: true

# TASK-039 ADR §4.14: Seed 4 enabled v1 sources + 4 disabled future placeholders.
# Future integration tasks (TASK-XXX IGDB / Helix / Twitter / Viral Clip) =
# create adapter class + UPDATE enabled=true. БЕЗ schema changes.
#
# Placeholders соответствуют конкретным ADR §4.14 future adapters —
# никаких vacuous future_adapter stubs.

class SeedAttributionSources < ActiveRecord::Migration[8.0]
  SOURCES = [
    # v1 enabled (ADR §4.14)
    {
      source: "raid_organic",
      enabled: true,
      priority: 10,
      adapter_class_name: "Trends::Attribution::RaidAdapter",
      display_label_en: "Organic raid",
      display_label_ru: "Органический рейд",
      metadata: { variant: "organic" }
    },
    {
      source: "raid_bot",
      enabled: true,
      priority: 11,
      adapter_class_name: "Trends::Attribution::RaidAdapter",
      display_label_en: "Bot raid",
      display_label_ru: "Бот-рейд",
      metadata: { variant: "bot" }
    },
    {
      source: "platform_cleanup",
      enabled: true,
      priority: 20,
      adapter_class_name: "Trends::Attribution::PlatformCleanupAdapter",
      display_label_en: "Platform cleanup",
      display_label_ru: "Очистка платформой",
      metadata: {}
    },

    # Future disabled placeholders (каждый — конкретный ADR §4.14 адаптер,
    # adapter_class_name готов к реализации в future integration task)
    {
      source: "igdb_release",
      enabled: false,
      priority: 30,
      adapter_class_name: "Trends::Attribution::IgdbAdapter",
      display_label_en: "Game release (IGDB)",
      display_label_ru: "Релиз игры (IGDB)",
      metadata: {}
    },
    {
      source: "helix_top100",
      enabled: false,
      priority: 40,
      adapter_class_name: "Trends::Attribution::HelixTopAdapter",
      display_label_en: "Twitch Top 100",
      display_label_ru: "Twitch Топ-100",
      metadata: {}
    },
    {
      source: "viral_clip",
      enabled: false,
      priority: 50,
      adapter_class_name: "Trends::Attribution::ViralClipAdapter",
      display_label_en: "Viral clip",
      display_label_ru: "Вирусный клип",
      metadata: {}
    },
    {
      source: "twitter_mention",
      enabled: false,
      priority: 60,
      adapter_class_name: "Trends::Attribution::TwitterAdapter",
      display_label_en: "Twitter/X mention",
      display_label_ru: "Упоминание в Twitter/X",
      metadata: {}
    },

    # Fallback (всегда last)
    {
      source: "unattributed",
      enabled: true,
      priority: 999,
      adapter_class_name: "Trends::Attribution::UnattributedFallback",
      display_label_en: "Unattributed",
      display_label_ru: "Без атрибуции",
      metadata: {}
    }
  ].freeze

  def up
    now = Time.current
    rows = SOURCES.map { |s| s.merge(created_at: now, updated_at: now) }
    AttributionSource.upsert_all(rows, unique_by: :source)

    # Invalidate cache for known_sources lookup (AnomalyAttribution validator).
    Rails.cache.delete(AttributionSource::CACHE_KEY) if defined?(AttributionSource)
  end

  def down
    AttributionSource.where(source: SOURCES.map { |s| s[:source] }).delete_all
    Rails.cache.delete(AttributionSource::CACHE_KEY) if defined?(AttributionSource)
  end
end
