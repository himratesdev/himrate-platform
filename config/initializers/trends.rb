# frozen_string_literal: true

# TASK-039 ADR §4.12: Cache versioning for Trends API responses.
# schema_version = 2 — matches trends_daily_aggregates.schema_version default +
# signal_configurations 'trends/cache/schema_version' seed (migration 100006).
#
# Bump этого значения при любом breaking change response shape (add/remove/rename fields
# в API или DB schema). Bump вместе с миграцией изменяющей schema_version default.
# Single source of truth для cache key format: trends:{channel_id}:{endpoint}:{period}:v{N}.

Rails.application.config.x.trends_cache_version = 2
