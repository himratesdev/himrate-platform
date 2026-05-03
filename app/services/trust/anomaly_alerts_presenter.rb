# frozen_string_literal: true

# TASK-085 FR-008/009/010/011/012/013/018 (ADR-085 D-4/D-7): Trust endpoint anomaly_alerts presenter.
# Facade поверх existing AnomalyAlerter pipeline + raid_attributions table — НЕ создаёт anomalies,
# только presents их per BRD external alert types contract (§2.2 mapping table).
#
# ADR-085 D-4: scoped к Trust::ShowService :drill_down/:full views (NOT :headline) — Pundit contract preserved.
# ADR-085 D-7: chat_entropy_drop reads anomaly.details.dig('signal_metadata', 'entropy_bits')
# (forwarded automatically by AnomalyAlerter line 36 — zero extra query).

module Trust
  class AnomalyAlertsPresenter
    PRESENTABLE_ANOMALY_TYPES = %w[
      ccv_step_function viewbot_spike anomaly_wave
      ti_drop chatter_ccv_ratio chat_behavior erv_divergence
    ].freeze

    WINDOW = 5.minutes
    RAID_LOOKBACK = 5.minutes
    RAID_SUPPRESS_CCV_SPIKE_WINDOW = 2.minutes

    SEVERITY_ORDER = %w[red yellow info].freeze
    CHAT_ENTROPY_THRESHOLD = 2.0

    # ccv_spike severity thresholds (signal_value of ccv_step_function = max z-score)
    CCV_SPIKE_RED_THRESHOLD = 2.0
    CCV_SPIKE_YELLOW_THRESHOLD = 1.0

    # ti_drop фиксированный threshold (filter в detector — здесь always red per BR-008)
    TI_DROP_THRESHOLD_PTS = 15.0

    # erv_divergence severity per BR-011
    ERV_DIVERGENCE_RED_THRESHOLD_PCT = 20.0
    ERV_DIVERGENCE_YELLOW_THRESHOLD_PCT = 10.0

    # chatter_to_ccv_anomaly category baseline multipliers (signal_value < baseline_min × X)
    CHATTER_RED_MULTIPLIER = 0.3
    CHATTER_YELLOW_MULTIPLIER = 0.5

    # Music/ASMR mapping per ADR-085 D-1 baseline storage decision (12 rows seed).
    CATEGORY_ALIASES = { "ASMR" => "Music" }.freeze

    DEFAULT_BASELINE_MIN = 65
    DEFAULT_BASELINE_MAX = 80

    def initialize(channel:)
      @channel = channel
    end

    # Returns Array<Hash> of presented alerts sorted by severity (red → yellow → info).
    # Empty Array если канал не live OR no recent anomalies/raids.
    def call
      return [] unless live_stream

      alerts = build_anomaly_alerts + build_raid_alerts
      alerts = suppress_ccv_spike_if_recent_raid(alerts)
      sort_by_severity(alerts)
    end

    private

    attr_reader :channel

    def live_stream
      @live_stream ||= channel.streams.where(ended_at: nil).order(started_at: :desc).first
    end

    def build_anomaly_alerts
      Anomaly.where(stream: live_stream)
             .where("timestamp > ?", WINDOW.ago)
             .where(anomaly_type: PRESENTABLE_ANOMALY_TYPES)
             .order(timestamp: :desc)
             .filter_map { |anomaly| map_anomaly(anomaly) }
    end

    def map_anomaly(anomaly)
      case anomaly.anomaly_type
      when "ccv_step_function", "viewbot_spike"
        build_ccv_spike(anomaly)
      when "anomaly_wave"
        build_anomaly_wave(anomaly)
      when "ti_drop"
        build_ti_drop(anomaly)
      when "chatter_ccv_ratio"
        build_chatter_to_ccv_anomaly(anomaly)
      when "chat_behavior"
        build_chat_entropy_drop(anomaly)
      when "erv_divergence"
        build_erv_divergence(anomaly)
      end
    end

    def build_ccv_spike(anomaly)
      signal_value = anomaly.details["signal_value"].to_f
      severity = signal_value >= CCV_SPIKE_RED_THRESHOLD ? "red" : "yellow"
      threshold = severity == "red" ? CCV_SPIKE_RED_THRESHOLD : CCV_SPIKE_YELLOW_THRESHOLD
      {
        id: anomaly.id,
        type: "ccv_spike",
        severity: severity,
        value: signal_value.round(2),
        threshold: threshold,
        window_minutes: 5,
        created_at: anomaly.timestamp.iso8601,
        metadata: { signal_value: signal_value.round(4) }
      }
    end

    def build_anomaly_wave(anomaly)
      {
        id: anomaly.id,
        type: "anomaly_wave",
        severity: "red",
        value: anomaly.details["signal_value"]&.to_f&.round(2),
        threshold: nil,
        window_minutes: 5,
        created_at: anomaly.timestamp.iso8601,
        metadata: anomaly.details.except("signal_value")
      }
    end

    def build_ti_drop(anomaly)
      {
        id: anomaly.id,
        type: "ti_drop",
        severity: "red",
        value: anomaly.details["delta_pts"]&.to_f,
        threshold: TI_DROP_THRESHOLD_PTS,
        window_minutes: anomaly.details["window_minutes"]&.to_i || 30,
        created_at: anomaly.timestamp.iso8601,
        metadata: {
          from_score: anomaly.details["from_score"],
          to_score: anomaly.details["to_score"]
        }
      }
    end

    def build_chatter_to_ccv_anomaly(anomaly)
      signal_value = anomaly.details["signal_value"].to_f
      category = (live_stream.game_name.presence || "default")
      category = CATEGORY_ALIASES[category] || category

      baseline_min = lookup_baseline(category, "baseline_min")
      baseline_max = lookup_baseline(category, "baseline_max")

      red_threshold = baseline_min * CHATTER_RED_MULTIPLIER
      yellow_threshold = baseline_min * CHATTER_YELLOW_MULTIPLIER

      severity = if signal_value < red_threshold
                   "red"
      elsif signal_value < yellow_threshold
                   "yellow"
      end
      return nil unless severity

      {
        id: anomaly.id,
        type: "chatter_to_ccv_anomaly",
        severity: severity,
        value: signal_value.round(2),
        threshold: yellow_threshold.round(2),
        window_minutes: 5,
        created_at: anomaly.timestamp.iso8601,
        metadata: {
          category: category,
          baseline_min: baseline_min,
          baseline_max: baseline_max
        }
      }
    end

    # ADR-085 D-7 OVERRIDE: read entropy_bits from anomaly.details.signal_metadata
    # (AnomalyAlerter forwards signal_metadata automatically — zero extra query vs SA recommendation).
    def build_chat_entropy_drop(anomaly)
      entropy = anomaly.details.dig("signal_metadata", "entropy_bits")&.to_f
      return nil if entropy.nil? || entropy >= CHAT_ENTROPY_THRESHOLD

      {
        id: anomaly.id,
        type: "chat_entropy_drop",
        severity: "red",
        value: entropy.round(2),
        threshold: CHAT_ENTROPY_THRESHOLD,
        window_minutes: 5,
        created_at: anomaly.timestamp.iso8601,
        metadata: { entropy_bits: entropy.round(2) }
      }
    end

    def build_erv_divergence(anomaly)
      delta_pct = anomaly.details["delta_pct"].to_f
      severity = delta_pct >= ERV_DIVERGENCE_RED_THRESHOLD_PCT ? "red" : "yellow"
      threshold = severity == "red" ? ERV_DIVERGENCE_RED_THRESHOLD_PCT : ERV_DIVERGENCE_YELLOW_THRESHOLD_PCT
      {
        id: anomaly.id,
        type: "erv_divergence",
        severity: severity,
        value: delta_pct.round(2),
        threshold: threshold,
        window_minutes: anomaly.details["window_minutes"]&.to_i || 15,
        created_at: anomaly.timestamp.iso8601,
        metadata: {
          from_erv_percent: anomaly.details["from_erv_percent"],
          to_erv_percent: anomaly.details["to_erv_percent"]
        }
      }
    end

    def build_raid_alerts
      RaidAttribution.where(stream: live_stream)
                     .where(is_bot_raid: false)
                     .where("timestamp > ?", RAID_LOOKBACK.ago)
                     .includes(:source_channel)
                     .order(timestamp: :desc)
                     .map { |raid| build_confirmed_raid(raid) }
    end

    def build_confirmed_raid(raid)
      {
        id: raid.id,
        type: "confirmed_raid",
        severity: "info",
        value: raid.raid_viewers_count,
        threshold: nil,
        window_minutes: 5,
        created_at: raid.timestamp.iso8601,
        metadata: {
          raider_name: raid.source_channel&.display_name,
          source_channel_id: raid.source_channel_id,
          viewers: raid.raid_viewers_count
        }
      }
    end

    # BR-021: ccv_spike suppressed когда confirmed_raid arrived в 2min ДО spike.
    def suppress_ccv_spike_if_recent_raid(alerts)
      raid_times = alerts.select { |a| a[:type] == "confirmed_raid" }
                         .map { |a| Time.zone.parse(a[:created_at]) }
      return alerts if raid_times.empty?

      alerts.reject do |alert|
        next false unless alert[:type] == "ccv_spike"

        spike_time = Time.zone.parse(alert[:created_at])
        raid_times.any? do |raid_time|
          gap = spike_time - raid_time
          gap >= 0 && gap <= RAID_SUPPRESS_CCV_SPIKE_WINDOW
        end
      end
    end

    def sort_by_severity(alerts)
      alerts.sort_by do |alert|
        [
          SEVERITY_ORDER.index(alert[:severity]) || SEVERITY_ORDER.size,
          -Time.zone.parse(alert[:created_at]).to_i
        ]
      end
    end

    def lookup_baseline(category, param_name)
      SignalConfiguration.value_for("chatter_ccv_ratio", category, param_name).to_f
    rescue SignalConfiguration::ConfigurationMissing
      param_name == "baseline_min" ? DEFAULT_BASELINE_MIN : DEFAULT_BASELINE_MAX
    end
  end
end
