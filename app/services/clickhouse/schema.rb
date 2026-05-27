# frozen_string_literal: true

module Clickhouse
  # Applies the committed ClickHouse DDL (db/clickhouse/*.sql). ClickHouse has no migration framework,
  # so this is the thin "run from scratch, converge to the current schema" applier — each file is
  # idempotent (CREATE ... IF NOT EXISTS), so it is safe on every deploy/CI run. The CH database
  # itself is created by the accessory (CLICKHOUSE_DB) / the CI service; this manages tables & views.
  #
  # Lives in app/services (autoloadable) rather than the rake file so the `statements` splitter is
  # unit-testable and the constant/helper don't leak onto Object (rake top-level eval gotcha).
  module Schema
    DIR = Rails.root.join("db/clickhouse")

    module_function

    # Schema files in apply order (numbered: 001_, 002_, ...).
    def files
      Dir[DIR.join("*.sql")].sort
    end

    # Split a .sql file into executable statements on `;` line-endings, dropping comment-only / blank
    # fragments (e.g. a trailing comment block after the final statement). Inline `--` comments inside
    # a statement are kept — ClickHouse accepts them.
    def statements(raw)
      raw.split(/;\s*$/m).filter_map do |fragment|
        code_only = fragment.gsub(/^\s*--.*$/, "").strip
        fragment.strip unless code_only.empty?
      end
    end
  end
end
