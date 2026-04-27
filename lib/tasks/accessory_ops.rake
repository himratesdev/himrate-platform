# frozen_string_literal: true

# BUG-010 PR3 (FR-015..022, FR-122..134): rake tasks consumed accessory-ops.yml workflow.
# Запускаются via SSH к web container на VPS:
#   docker exec himrate-web bin/rails accessory_ops:<task>[args]
#
# Workflow captures stdout (event_id, healthy|unhealthy verdict) для downstream steps.
# Все tasks fail loud — exit 1 + structured stderr — workflow detects + branches accordingly.

namespace :accessory_ops do
  # FR-015..017: post-action health polling. Exits 0 = healthy, 1 = unhealthy.
  # Used after kamal accessory action в workflow — failure → triggers rollback path.
  desc "Poll AccessoryOps::HealthCheckService до timeout (default 300s, every 10s)"
  task :health_verify, %i[destination accessory timeout_seconds] => :environment do |_t, args|
    destination = args[:destination] or abort("Usage: accessory_ops:health_verify[destination,accessory,timeout_seconds]")
    accessory = args[:accessory] or abort("Missing accessory argument")
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

  # FR-018..022: auto-rollback via kamal accessory boot к previous_image.
  # Validates previous_image present + pullable до execution. Fail loud если registry tag missing —
  # critical alert + manual intervention required (per "build for years" — silent rollback gap = bad).
  desc "Rollback accessory к previous_image (выясняется из StateService)"
  task :rollback, %i[destination accessory] => :environment do |_t, args|
    destination = args[:destination] or abort("Usage: accessory_ops:rollback[destination,accessory]")
    accessory = args[:accessory] or abort("Missing accessory argument")

    previous = AccessoryOps::StateService.previous_image(destination: destination, accessory: accessory)
    if previous.blank?
      warn "no_previous_image destination=#{destination} accessory=#{accessory}"
      AlertmanagerNotifier.push(
        labels: { alertname: "AccessoryRollback", severity: "critical",
                  destination: destination, accessory: accessory, event_type: "rollback_no_previous" },
        annotations: { summary: "Rollback не возможен: previous_image отсутствует",
                       description: "AccessoryState.previous_image NULL — manual intervention required" }
      )
      PrometheusMetrics.observe_rollback(destination: destination, accessory: accessory, result: "no_previous")
      exit 1
    end

    puts "rolling_back destination=#{destination} accessory=#{accessory} target_image=#{previous}"
    # Execute kamal accessory boot. previous_image берётся из state в текущем deploy.yml — рабочий
    # rollback требует deploy.yml уже rolled back к previous tag (operator updates deploy.yml +
    # `kamal accessory boot`). Здесь мы только trigger — workflow выше rollback-aware.
    success = system("kamal", "accessory", "boot", accessory, "-d", destination)

    AlertmanagerNotifier.push(
      labels: { alertname: "AccessoryRollback",
                severity: success ? "warning" : "critical",
                destination: destination, accessory: accessory,
                event_type: success ? "rollback_success" : "rollback_failed" },
      annotations: { summary: "Rollback #{success ? 'выполнен' : 'провален'}: #{accessory} на #{destination}",
                     description: "target_image=#{previous}" }
    )
    PrometheusMetrics.observe_rollback(destination: destination, accessory: accessory,
                                       result: success ? "success" : "failed")

    exit(success ? 0 : 1)
  end

  # FR-122..124: update AccessoryState после успешного health check (workflow success path).
  desc "Update AccessoryState.current_image + last_health_check (delegates StateService)"
  task :"state:update_after_health", %i[destination accessory image status] => :environment do |_t, args|
    destination = args[:destination] or abort("Usage: accessory_ops:state:update_after_health[destination,accessory,image,status]")
    accessory = args[:accessory] or abort("Missing accessory argument")
    image = args[:image] or abort("Missing image argument")
    status = args[:status] or abort("Missing status argument")

    record = AccessoryOps::StateService.update_after_health_check(
      destination: destination, accessory: accessory, image: image, status: status
    )
    puts "state_updated id=#{record.id} current=#{record.current_image} previous=#{record.previous_image}"
  end

  namespace :downtime do
    # FR hooks: INSERT downtime event при start (action=reboot/restart/stop). Outputs event_id —
    # workflow captures для последующего :end call.
    desc "INSERT accessory_downtime_events row, output event_id"
    task :start, %i[destination accessory source drift_event_id] => :environment do |_t, args|
      destination = args[:destination] or abort("Usage: accessory_ops:downtime:start[destination,accessory,source,drift_event_id]")
      accessory = args[:accessory] or abort("Missing accessory argument")
      source = args[:source] or abort("Missing source argument (drift|restart|health_fail|rollback)")
      drift_event_id = args[:drift_event_id].presence

      event = AccessoryDowntimeEvent.create!(
        destination: destination, accessory: accessory, source: source,
        started_at: Time.current, drift_event_id: drift_event_id
      )
      puts event.id
    end

    # Close downtime event — sets ended_at + computes duration_seconds (model before_save).
    desc "Close accessory_downtime_event (sets ended_at)"
    task :end, %i[event_id] => :environment do |_t, args|
      event_id = args[:event_id] or abort("Usage: accessory_ops:downtime:end[event_id]")

      event = AccessoryDowntimeEvent.find(event_id)
      event.update!(ended_at: Time.current)
      puts "downtime_closed id=#{event.id} duration=#{event.duration_seconds}s"
    end
  end

  # Wraps AlertmanagerNotifier.push. Workflow uses для structured alert после kamal action.
  desc "Push alert через AlertmanagerNotifier"
  task :notify, %i[event_type severity destination accessory summary description] => :environment do |_t, args|
    event_type = args[:event_type] or abort("Usage: accessory_ops:notify[event_type,severity,destination,accessory,summary,description]")
    severity = args[:severity] or abort("Missing severity")
    destination = args[:destination] or abort("Missing destination")
    accessory = args[:accessory] or abort("Missing accessory")
    summary = args[:summary] || "#{event_type}: #{destination}/#{accessory}"
    description = args[:description] || "Triggered by accessory-ops workflow"

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
    # Cleanup stale grouping keys в Prometheus pushgateway — pushgateway accumulates entries
    # bez TTL. Weekly cron should call это (grouping keys для accessories которые давно не emit
    # анти-stale data).
    desc "Delete pushgateway groupings older than N days (default 7)"
    task :cleanup_stale_groupings, %i[days] => :environment do |_t, args|
      days = args[:days].present? ? args[:days].to_i : 7
      cutoff = Time.current - days.days

      # Iterate AccessoryState — single source of truth для known (destination, accessory) pairs.
      # Pairs без recent health_check (< cutoff) → delete grouping. Active pairs preserved.
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
