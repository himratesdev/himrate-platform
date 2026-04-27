# frozen_string_literal: true

# BUG-010 PR2 (FR-125/126, Edge#29): file cache mirror of accessory_states.
# Workflow rollback step uses cache когда DB down. Hourly worker mirrors DB → file.
# Workflow reads via SSH (cat /var/lib/himrate/accessory-state-cache/<accessory>.json).

module AccessoryOps
  class StateCacheService
    CACHE_DIR = "/var/lib/himrate/accessory-state-cache"

    def self.write_all
      AccessoryState.find_each(&method(:write_one))
    end

    def self.write_one(state)
      payload = {
        destination: state.destination,
        accessory: state.accessory,
        current_image: state.current_image,
        previous_image: state.previous_image,
        last_health_check_at: state.last_health_check_at&.iso8601,
        last_health_status: state.last_health_status,
        cached_at: Time.current.iso8601
      }

      filename = "#{state.destination}_#{state.accessory}.json"
      path = File.join(CACHE_DIR, filename)

      FileUtils.mkdir_p(CACHE_DIR)
      File.atomic_write(path) { |f| f.write(JSON.pretty_generate(payload)) }
      File.chmod(0o600, path)
      path
    end

    def self.read(destination:, accessory:)
      filename = "#{destination}_#{accessory}.json"
      path = File.join(CACHE_DIR, filename)
      return nil unless File.exist?(path)

      JSON.parse(File.read(path))
    end
  end
end
