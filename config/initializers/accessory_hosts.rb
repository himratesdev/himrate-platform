# frozen_string_literal: true

# BUG-010 PR2: load + validate config/accessory_hosts.yml at boot. Fail-fast per ADR DEC-6.

module AccessoryHostsConfig
  CONFIG_PATH = Rails.root.join("config/accessory_hosts.yml")

  class << self
    def hosts_for(destination)
      config.fetch(destination.to_s) do
        raise KeyError, "AccessoryHostsConfig: unknown destination=#{destination}. Known: #{destinations.inspect}"
      end
    end

    def destinations
      config.keys
    end

    def reload!
      @config = load_config
    end

    private

    def config
      @config ||= load_config
    end

    def load_config
      raw = YAML.load_file(CONFIG_PATH)
      raise "AccessoryHostsConfig: config must be a Hash, got #{raw.class}" unless raw.is_a?(Hash)

      raw.each do |destination, hosts|
        unless hosts.is_a?(Array) && hosts.all? { |h| h.is_a?(String) && !h.empty? }
          raise "AccessoryHostsConfig: #{destination} must be Array of non-empty Strings, got #{hosts.inspect}"
        end
      end

      raw
    end
  end
end

# Fail-fast at boot: surface config errors immediately, не lazy load.
AccessoryHostsConfig.send(:config) if Rails.env.production? || Rails.env.staging?
