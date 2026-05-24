# frozen_string_literal: true

# Configure Active Record Encryption from ENV vars.
# Required for AuthProvider.encrypts :access_token, :refresh_token
encryption_keys = %w[PRIMARY_KEY DETERMINISTIC_KEY KEY_DERIVATION_SALT].map { |k|
  ENV["ACTIVE_RECORD_ENCRYPTION_#{k}"]
}

if encryption_keys.any?(&:present?)
  raise "Incomplete Active Record Encryption config: all 3 keys required" unless encryption_keys.all?(&:present?)

  # BUG-028: apply via ActiveRecord::Encryption.configure, NOT
  # `config.active_record.encryption.x=`. config/initializers/* run after the
  # `active_record.encryption` railtie has already applied config.active_record.encryption
  # to the live ActiveRecord::Encryption.config — so a late `config.x=` here never reaches
  # it, leaving primary_key nil → "Missing Active Record encryption credential" on the first
  # encrypted write (AuthProvider tokens). configure(...) sets the live config directly.
  ActiveRecord::Encryption.configure(
    primary_key: ENV["ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY"],
    deterministic_key: ENV["ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY"],
    key_derivation_salt: ENV["ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT"]
  )
end
