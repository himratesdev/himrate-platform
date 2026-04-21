# frozen_string_literal: true

# TASK-028 FR-015: Dynamic signal configuration from DB.
# Stores thresholds, weights, and interaction parameters.
# All signal classes read config from here, not hardcoded constants.

class SignalConfiguration < ApplicationRecord
  validates :signal_type, presence: true
  validates :category, presence: true
  validates :param_name, presence: true
  validates :param_value, presence: true
  validates :signal_type, uniqueness: { scope: %i[category param_name] }

  scope :for_signal, ->(signal_type, category) {
    where(signal_type: signal_type, category: category)
  }

  # Fetch a single param value. Raises if not found (seed data is mandatory).
  #
  # CR W-3: Request/job-scoped memoization через Current.signal_config для
  # избежания N lookups амплификации. 30-50 SignalConfiguration reads per
  # Trends endpoint compress в ~10-15 unique DB reads + memoized hits. Cache
  # auto-resets на конец request/job (ActiveSupport::CurrentAttributes),
  # поэтому admin DB update видна на следующем запросе/job — без manual invalidation.
  def self.value_for(signal_type, category, param_name)
    Current.signal_config ||= {}
    key = [ signal_type, category, param_name ]
    return Current.signal_config[key] if Current.signal_config.key?(key)

    record = find_by(signal_type: signal_type, category: category, param_name: param_name)
    record ||= find_by(signal_type: signal_type, category: "default", param_name: param_name)

    raise ConfigurationMissing, "Missing config: #{signal_type}/#{category}/#{param_name}" unless record

    Current.signal_config[key] = record.param_value
  end

  # Fetch all params for a signal+category as a Hash.
  def self.params_for(signal_type, category)
    configs = for_signal(signal_type, category)
    configs = for_signal(signal_type, "default") if configs.empty?

    raise ConfigurationMissing, "Missing config for #{signal_type}/#{category}" if configs.empty?

    configs.each_with_object({}) { |c, h| h[c.param_name] = c.param_value }
  end

  class ConfigurationMissing < StandardError; end
end
