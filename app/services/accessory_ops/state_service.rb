# frozen_string_literal: true

# BUG-010 PR2 (ADR DEC-23, FR-122/123/124): State CRUD — DB-backed.
# Replaces FR-022 file pattern. Workflow + worker access via this service.
#
# Atomic update: read current → update via transaction. Cache mirror handled separately
# в StateCacheService (hourly cron).

module AccessoryOps
  class StateService
    def self.find_or_create(destination:, accessory:, current_image: nil)
      record = AccessoryState.find_or_initialize_by(destination: destination, accessory: accessory)
      if record.new_record?
        # First-time deploy: previous=current=new (per FR-022 lifecycle).
        record.current_image = current_image if current_image
        record.previous_image = current_image
        record.save!
      end
      record
    end

    def self.update_after_health_check(destination:, accessory:, image:, status:)
      AccessoryState.transaction do
        record = AccessoryState.lock.find_by(destination: destination, accessory: accessory)
        unless record
          record = AccessoryState.create!(
            destination: destination,
            accessory: accessory,
            current_image: image,
            previous_image: image,
            last_health_check_at: Time.current,
            last_health_status: status
          )
          return record
        end

        if record.current_image != image
          record.previous_image = record.current_image
          record.current_image = image
        end
        record.last_health_check_at = Time.current
        record.last_health_status = status
        record.save!
        record
      end
    end

    def self.previous_image(destination:, accessory:)
      AccessoryState.find_by(destination: destination, accessory: accessory)&.previous_image
    end
  end
end
