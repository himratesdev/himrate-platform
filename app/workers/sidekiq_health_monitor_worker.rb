# frozen_string_literal: true

# BUG-010 PR2 (ADR DEC-5): Sidekiq health heartbeat monitor.
# Runs every 30 min via cron. Critical alert если AccessoryDriftDetectorWorker
# heartbeat stale >2h (worker not running).

class SidekiqHealthMonitorWorker
  include Sidekiq::Job
  sidekiq_options queue: :monitoring, retry: 2

  STALE_THRESHOLD = 2.hours

  def perform
    last_run = Sidekiq::Cron::Job.find("accessory_drift_detector")&.last_enqueue_time
    return push_alert("drift_detector_unscheduled", "Sidekiq cron job 'accessory_drift_detector' not registered") unless last_run

    age = Time.current - last_run
    return if age < STALE_THRESHOLD

    push_alert(
      "drift_detector_stale",
      "AccessoryDriftDetectorWorker heartbeat stale: last_run=#{last_run.iso8601} age=#{age.to_i}s"
    )
  end

  private

  def push_alert(event_type, message)
    AlertmanagerNotifier.push(
      labels: {
        alertname: "SidekiqHealthMonitor",
        severity: "critical",
        event_type: event_type
      },
      annotations: {
        summary: "Sidekiq health: #{event_type}",
        description: message
      }
    )
  rescue StandardError => e
    Rails.logger.error("SidekiqHealthMonitorWorker: alert push failed — #{e.class}: #{e.message}")
  end
end
