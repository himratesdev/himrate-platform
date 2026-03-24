# frozen_string_literal: true

# Configure Active Record Encryption from ENV vars.
# Required for AuthProvider.encrypts :access_token, :refresh_token
encryption_keys = %w[PRIMARY_KEY DETERMINISTIC_KEY KEY_DERIVATION_SALT].map { |k|
  ENV["ACTIVE_RECORD_ENCRYPTION_#{k}"]
}

if encryption_keys.any?(&:present?)
  raise "Incomplete Active Record Encryption config: all 3 keys required" unless encryption_keys.all?(&:present?)

  Rails.application.config.active_record.encryption.primary_key = ENV["ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY"]
  Rails.application.config.active_record.encryption.deterministic_key = ENV["ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY"]
  Rails.application.config.active_record.encryption.key_derivation_salt = ENV["ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT"]
end
