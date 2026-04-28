# frozen_string_literal: true

# BUG-010 PR3 (FR-015..022, FR-122..134): rake tasks consumed accessory-ops.yml workflow.
# Запускаются via SSH к web container на VPS:
#   docker exec [-i] himrate-web bin/rails accessory_ops:<task>[args]
#
# Workflow captures stdout (event_id, healthy|unhealthy verdict) для downstream steps.
# Все tasks fail loud — exit 1 + structured stderr — workflow detects + branches accordingly.
#
# CR M-4 (defense-in-depth): каждый task с (destination, accessory) args validates через
# AccessoryOps::DriftCheckService::ALLOWED_DESTINATIONS/ALLOWED_ACCESSORIES. Workflow type:
# choice enums GitHub-side, но enforce здесь explicitly — paranoia.

require "json"

namespace :accessory_ops do
  # Validation helper — reused всеми tasks с (destination, accessory) args.
  validate_pair = lambda do |destination, accessory|
    unless AccessoryOps::DriftCheckService::ALLOWED_DESTINATIONS.include?(destination)
      abort "invalid destination=#{destination.inspect} (allowed: #{AccessoryOps::DriftCheckService::ALLOWED_DESTINATIONS.inspect})"
    end
    unless AccessoryOps::DriftCheckService::ALLOWED_ACCESSORIES.include?(accessory)
      abort "invalid accessory=#{accessory.inspect} (allowed: #{AccessoryOps::DriftCheckService::ALLOWED_ACCESSORIES.inspect})"
    end
  end

  # FR-015..017: post-action health polling. Exits 0 = healthy, 1 = unhealthy.
  # Used after kamal accessory action в workflow — failure → triggers rollback path.
  desc "Poll AccessoryOps::HealthCheckService до timeout (default 300s, every 10s)"
  task :health_verify, %i[destination accessory timeout_seconds] => :environment do |_t, args|
    destination = args[:destination] or abort("Usage: accessory_ops:health_verify[destination,accessory,timeout_seconds]")
    accessory = args[:accessory] or abort("Missing accessory argument")
    validate_pair.call(destination, accessory)
    timeout = args[:timeout_seconds].present? ? args[:timeout_seconds].to_i : 300

    deadline = Time.current + timeout
    attempt = 0
    last_status = nil

    loop do
      attempt += 1
      result = AccessoryOps::HealthCheckService.call(destination: destination, accessory: accessory)
      last_status = result.status
      if result.healthy?
        puts "healthy attempts=#{attempt} status=#{result.status}"
        exit 0
      end

      if Time.current >= deadline
        warn "unhealthy attempts=#{attempt} status=#{last_status} timeout=#{timeout}s"
        PrometheusMetrics.observe_health_failure(destination: destination, accessory: accessory)
        exit 1
      end

      sleep(10)
    end
  end

  # FR-018..022 (CR B-2 honest naming): "rollback intent" — requests Kamal к restart accessory
  # с current deploy.yml image. ТОЧНЫЙ image revert через CLI Kamal не поддерживает, real
  # auto-rollback требует programmatic deploy.yml edit + commit + redeploy (TASK-083 deferred —
  # высокий blast radius, постpone к manual operator path). Validates previous_image present
  # AND differs от current — иначе no-op exit 0.
  desc "Request Kamal restart accessory (intent: revert. Real image revert requires deploy.yml edit — see TASK-083)"
  task :rollback_intent, %i[destination accessory] => :environment do |_t, args|
    destination = args[:destination] or abort("Usage: accessory_ops:rollback_intent[destination,accessory]")
    accessory = args[:accessory] or abort("Missing accessory argument")
    validate_pair.call(destination, accessory)

    state = AccessoryState.find_by(destination: destination, accessory: accessory)
    if state.nil?
      warn "no_state destination=#{destination} accessory=#{accessory}"
      exit 1
    end

    if state.previous_image.blank?
      warn "no_previous_image destination=#{destination} accessory=#{accessory} current=#{state.current_image}"
      AlertmanagerNotifier.push(
        labels: { alertname: "AccessoryRollback", severity: "critical",
                  destination: destination, accessory: accessory, event_type: "rollback_no_previous" },
        annotations: { summary: "Rollback intent невозможен: previous_image отсутствует",
                       description: "AccessoryState.previous_image NULL — manual operator intervention required" }
      )
      PrometheusMetrics.observe_rollback(destination: destination, accessory: accessory, result: "no_previous")
      exit 1
    end

    if state.previous_image == state.current_image
      warn "no_op_rollback destination=#{destination} accessory=#{accessory} current=previous=#{state.current_image}"
      exit 1
    end

    puts "rollback_intent destination=#{destination} accessory=#{accessory} target_image=#{state.previous_image} current_image=#{state.current_image}"
    # NB: kamal accessory boot uses image из current deploy.yml. Если deploy.yml not yet
    # rolled back, this just restarts с current_image — НЕ reverts. Real revert = TASK-083.
    success = system("kamal", "accessory", "boot", accessory, "-d", destination)

    AlertmanagerNotifier.push(
      labels: { alertname: "AccessoryRollback",
                severity: success ? "warning" : "critical",
                destination: destination, accessory: accessory,
                event_type: success ? "rollback_intent_executed" : "rollback_intent_failed" },
      annotations: { summary: "Kamal accessory boot #{success ? 'выполнен' : 'провален'}: #{accessory} на #{destination}",
                     description: "target_image=#{state.previous_image} current_image=#{state.current_image} — manual deploy.yml revert may be required" }
    )
    PrometheusMetrics.observe_rollback(destination: destination, accessory: accessory,
                                       result: success ? "executed" : "failed")
    exit(success ? 0 : 1)
  end

  # FR-122..124: update AccessoryState после успешного health check (workflow success path).
  desc "Update AccessoryState.current_image + last_health_check (delegates StateService)"
  task :"state:update_after_health", %i[destination accessory image status] => :environment do |_t, args|
    destination = args[:destination] or abort("Usage: accessory_ops:state:update_after_health[destination,accessory,image,status]")
    accessory = args[:accessory] or abort("Missing accessory argument")
    image = args[:image] or abort("Missing image argument")
    status = args[:status] or abort("Missing status argument")
    validate_pair.call(destination, accessory)

    record = AccessoryOps::StateService.update_after_health_check(
      destination: destination, accessory: accessory, image: image, status: status
    )
    puts "state_updated id=#{record.id} current=#{record.current_image} previous=#{record.previous_image}"
  end

  # Workflow-friendly wrapper: reads runtime image via DriftCheckService, then persists.
  desc "Refresh AccessoryState с runtime image (DriftCheckService + StateService)"
  task :"state:refresh", %i[destination accessory status] => :environment do |_t, args|
    destination = args[:destination] or abort("Usage: accessory_ops:state:refresh[destination,accessory,status]")
    accessory = args[:accessory] or abort("Missing accessory argument")
    validate_pair.call(destination, accessory)
    status = args[:status] || "healthy"

    drift = AccessoryOps::DriftCheckService.call(destination: destination, accessory: accessory)
    image = drift.runtime_image
    if image.blank?
      warn "state_refresh_failed runtime_image_unknown destination=#{destination} accessory=#{accessory}"
      exit 1
    end

    record = AccessoryOps::StateService.update_after_health_check(
      destination: destination, accessory: accessory, image: image, status: status
    )
    puts "state_refreshed id=#{record.id} current=#{record.current_image} previous=#{record.previous_image} status=#{record.last_health_status}"
  end

  namespace :downtime do
    desc "INSERT accessory_downtime_events row, output event_id"
    task :start, %i[destination accessory source drift_event_id] => :environment do |_t, args|
      destination = args[:destination] or abort("Usage: accessory_ops:downtime:start[destination,accessory,source,drift_event_id]")
      accessory = args[:accessory] or abort("Missing accessory argument")
      source = args[:source] or abort("Missing source argument (drift|restart|health_fail|rollback)")
      validate_pair.call(destination, accessory)
      drift_event_id = args[:drift_event_id].presence

      event = AccessoryDowntimeEvent.create!(
        destination: destination, accessory: accessory, source: source,
        started_at: Time.current, drift_event_id: drift_event_id
      )
      puts event.id
    end

    desc "Close accessory_downtime_event (sets ended_at)"
    task :end, %i[event_id] => :environment do |_t, args|
      event_id = args[:event_id] or abort("Usage: accessory_ops:downtime:end[event_id]")

      event = AccessoryDowntimeEvent.find(event_id)
      event.update!(ended_at: Time.current)
      puts "downtime_closed id=#{event.id} duration=#{event.duration_seconds}s"
    end
  end

  # CR B-1: notify reads JSON payload из STDIN — bulletproof против commas/spaces/quotes
  # в summary/description. Workflow: printf '{"event_type":"...",...}' | docker exec -i ...
  # Required keys: event_type, severity, destination, accessory. Optional: summary, description.
  desc "Push alert через AlertmanagerNotifier (JSON payload from STDIN)"
  task notify: :environment do
    payload = JSON.parse($stdin.read)
    event_type = payload.fetch("event_type")
    severity = payload.fetch("severity")
    destination = payload.fetch("destination")
    accessory = payload.fetch("accessory")
    summary = payload["summary"].presence || "#{event_type}: #{destination}/#{accessory}"
    description = payload["description"].presence || "Triggered by accessory-ops workflow"

    validate_pair.call(destination, accessory)

    AlertmanagerNotifier.push(
      labels: { alertname: "AccessoryOps", severity: severity,
                destination: destination, accessory: accessory, event_type: event_type },
      annotations: { summary: summary, description: description }
    )
    puts "notified event_type=#{event_type} severity=#{severity}"
  end

  namespace :auto_remediation do
    desc "Enable :accessory_auto_remediation Flipper flag"
    task enable: :environment do
      Flipper.add(:accessory_auto_remediation)
      Flipper.enable(:accessory_auto_remediation)
      puts "auto_remediation_enabled flag=:accessory_auto_remediation state=enabled"
    end

    desc "Disable :accessory_auto_remediation Flipper flag (kill switch)"
    task disable: :environment do
      Flipper.disable(:accessory_auto_remediation)
      puts "auto_remediation_disabled flag=:accessory_auto_remediation state=disabled"
    end
  end

  namespace :metrics do
    desc "Delete pushgateway groupings older than N days (default 7)"
    task :cleanup_stale_groupings, %i[days] => :environment do |_t, args|
      days = args[:days].present? ? args[:days].to_i : 7
      cutoff = Time.current - days.days

      stale = AccessoryState.where("last_health_check_at < ? OR last_health_check_at IS NULL", cutoff)
      jobs = %w[accessory_ops accessory_drift accessory_health accessory_rollback accessory_cost]
      deleted = 0
      stale.find_each do |state|
        jobs.each do |job|
          PrometheusMetrics.delete_grouping(
            job: job, grouping: { destination: state.destination, accessory: state.accessory }
          )
          deleted += 1
        end
      end
      puts "cleanup_stale_groupings stale_pairs=#{stale.count} deleted=#{deleted} cutoff=#{cutoff.iso8601}"
    end
  end
end
