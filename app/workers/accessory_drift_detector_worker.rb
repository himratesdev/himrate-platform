# frozen_string_literal: true

# BUG-010 PR2 (FR-024..029): hourly drift detection across destinations + accessories.
# Compares declared (deploy.yml) vs runtime (kamal accessory details parse) per pair.
# Idempotent: open drift_event uniquely scoped per (destination, accessory) via partial unique index.
# Production drift → AutoRemediation::TriggerService (Flipper-gated). All drift → AlertManager push.

class AccessoryDriftDetectorWorker
  include Sidekiq::Job
  sidekiq_options queue: :accessory_ops, retry: 3

  ACCESSORIES = %w[db redis grafana prometheus loki alertmanager promtail prometheus-pushgateway clickhouse].freeze

  def perform
    return unless Flipper.enabled?(:accessory_drift_detection)

    @skipped_count = 0
    AccessoryHostsConfig.destinations.each do |destination|
      ACCESSORIES.each do |accessory|
        check_pair(destination: destination, accessory: accessory)
      end
    end

    # BUG-025: aggregate :skipped log marker — one line per cycle instead of N×accessory warnings.
    # The detailed root-cause warning is already emitted once-per-cycle by DriftCheckService when
    # the config-unreadable code path fires. This counter is observability: grep
    # "drift detection skipped" → see "N/M pairs unable to check declared image this cycle".
    if @skipped_count.positive?
      Rails.logger.info(
        "AccessoryDriftDetectorWorker: drift detection skipped for #{@skipped_count} pair(s) " \
        "(config/deploy.yml not mounted in container — see DriftCheckService warning; BUG-025)"
      )
    end
  end

  def check_pair(destination:, accessory:)
    result = AccessoryOps::DriftCheckService.call(destination: destination, accessory: accessory)
    open_event = AccessoryDriftEvent.open_events.for_pair(destination, accessory).first

    case result.drift_state
    when :match
      close_event!(open_event) if open_event
    when :mismatch
      handle_mismatch!(destination: destination, accessory: accessory, result: result, open_event: open_event)
    when :skipped
      # BUG-025: config/deploy.yml not present in container → DriftCheckService cannot read the
      # declared image. No state change — do NOT close `open_event` (drift detection is paused for
      # this cycle, NOT "resolved" — falsely closing would lose visibility into a real ongoing drift
      # the moment the config becomes unreadable). DriftCheckService logs the root-cause warning;
      # we only bump the per-cycle counter for the aggregate log marker in #perform.
      @skipped_count = @skipped_count.to_i + 1
    end
  rescue StandardError => e
    Rails.logger.error("AccessoryDriftDetectorWorker: #{destination}/#{accessory} — #{e.class}: #{e.message}")
    raise # surface to Sidekiq retry mechanism
  end

  private

  def close_event!(event)
    event.update!(status: "resolved", resolved_at: Time.current)
    push_alert(event_type: "drift_resolved", severity: "info", drift_event: event)
    Rails.logger.info("AccessoryDriftDetectorWorker: resolved drift_event=#{event.id}")
  end

  def handle_mismatch!(destination:, accessory:, result:, open_event:)
    if open_event
      # Idempotent: do not duplicate alert OR row. State unchanged.
      return
    end

    event = AccessoryDriftEvent.create!(
      destination: destination,
      accessory: accessory,
      declared_image: result.declared_image,
      runtime_image: result.runtime_image,
      detected_at: Time.current,
      status: "open",
      alert_sent_at: Time.current
    )

    severity = destination == "production" ? "warning" : "info"
    push_alert(event_type: "drift_open", severity: severity, drift_event: event)

    AccessoryOps::AutoRemediation::TriggerService.call(
      destination: destination,
      accessory: accessory,
      drift_event_id: event.id
    )
  end

  def push_alert(event_type:, severity:, drift_event:)
    AlertmanagerNotifier.push(
      labels: {
        alertname: "AccessoryDrift",
        severity: severity,
        accessory: drift_event.accessory,
        destination: drift_event.destination,
        event_type: event_type
      },
      annotations: {
        summary: "Accessory drift #{event_type}: #{drift_event.destination}/#{drift_event.accessory}",
        description: "declared=#{drift_event.declared_image} runtime=#{drift_event.runtime_image}"
      }
    )
  rescue StandardError => e
    Rails.logger.warn("AccessoryDriftDetectorWorker: alert push failed — #{e.class}: #{e.message}")
  end
end
