# frozen_string_literal: true

# TASK-086 FR-034: turn an exception raised during a cleanup sub-run into a
# PII-safe { error_code:, error_context: } pair for cleanup_audit_logs. NO free
# text, NO message strings that might contain UUIDs / emails / usernames.
#
# error_code = a short stable token (exception class short name, or the PG SQLSTATE
# for ActiveRecord::StatementInvalid family). error_context = a small jsonb hash
# of safe structured fields, with any UUID / email patterns redacted defensively.

module Cleanup
  class ErrorSerializer
    UUID_RE = /[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/
    EMAIL_RE = /\b[\w.+-]+@[\w-]+\.[\w.-]+\b/

    def self.sanitize(exception, table_name)
      {
        "error_code" => error_code_for(exception),
        "error_context" => {
          "table" => table_name.to_s,
          "error_class" => exception.class.name,
          "sql_state" => sql_state_for(exception)
        }.compact
      }
    rescue StandardError => e
      { "error_code" => "Unknown", "error_context" => { "table" => table_name.to_s, "serializer_error" => e.class.name } }
    end

    def self.error_code_for(exception)
      sql_state = sql_state_for(exception)
      return sql_state if sql_state

      redact(exception.class.name.demodulize)
    end

    def self.sql_state_for(exception)
      return nil unless exception.respond_to?(:cause) && exception.cause.respond_to?(:result)

      result = exception.cause.result
      result.respond_to?(:error_field) ? result.error_field(PG::Result::PG_DIAG_SQLSTATE) : nil
    rescue StandardError
      nil
    end

    def self.redact(value)
      value.to_s.gsub(UUID_RE, "[REDACTED_UUID]").gsub(EMAIL_RE, "[REDACTED_EMAIL]")
    end

    private_class_method :error_code_for, :sql_state_for, :redact
  end
end
