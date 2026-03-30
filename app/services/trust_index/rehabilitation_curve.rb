# frozen_string_literal: true

# TASK-029 FR-007/008: Rehabilitation Curve + Auto-Exoneration.
# 15 clean streams for full recovery. Bonus +15 pts max.
# Bot-raid victims: penalty NOT applied (Auto-Exoneration).

module TrustIndex
  class RehabilitationCurve
    # Returns {adjusted_ti: Float, penalty: Float, bonus: Float, clean_streams: Integer}
    def self.apply(channel:, calculated_ti:)
      incident = find_latest_incident(channel)

      return { adjusted_ti: calculated_ti, penalty: 0.0, bonus: 0.0, clean_streams: 0 } unless incident

      # FR-008: Auto-Exoneration — check if incident was bot-raid victim
      if bot_raid_victim?(channel, incident)
        return { adjusted_ti: calculated_ti, penalty: 0.0, bonus: 0.0, clean_streams: 0,
                 auto_exonerated: true }
      end

      clean_streams = count_clean_streams(channel, incident)
      rehab_streams = rehabilitation_streams_config
      initial_penalty = incident[:initial_penalty]

      # Penalty: decreases linearly over clean streams
      penalty = initial_penalty * [ 0.0, 1.0 - clean_streams / rehab_streams ].max

      # Bonus: +pts for high engagement during rehabilitation
      bonus = calculate_bonus(clean_streams, rehab_streams)

      adjusted_ti = (calculated_ti - penalty + bonus).clamp(0.0, 100.0)

      { adjusted_ti: adjusted_ti, penalty: penalty.round(2), bonus: bonus.round(2),
        clean_streams: clean_streams }
    end

    # Detect latest "incident" — a stream where TI dropped below threshold
    def self.find_latest_incident(channel)
      threshold = incident_threshold_config
      recent_histories = channel.trust_index_histories
        .where("trust_index_score < ?", threshold)
        .order(calculated_at: :desc)
        .first

      return nil unless recent_histories

      # Calculate initial penalty: how far below population mean
      pop_mean = population_mean_config
      initial_penalty = [ 0.0, pop_mean - recent_histories.trust_index_score ].max

      { calculated_at: recent_histories.calculated_at,
        initial_penalty: initial_penalty,
        stream_id: recent_histories.stream_id }
    end

    def self.count_clean_streams(channel, incident)
      threshold = incident_threshold_config
      channel.streams
        .joins("INNER JOIN trust_index_histories ON trust_index_histories.stream_id = streams.id")
        .where("streams.ended_at IS NOT NULL")
        .where("streams.started_at > ?", incident[:calculated_at])
        .where("trust_index_histories.trust_index_score >= ?", threshold)
        .distinct
        .count
    end

    def self.bot_raid_victim?(channel, incident)
      return false unless incident[:stream_id]

      RaidAttribution.where(stream_id: incident[:stream_id], is_bot_raid: true).exists?
    end

    def self.calculate_bonus(clean_streams, rehab_streams)
      return 0.0 if clean_streams.zero? || clean_streams >= rehab_streams

      max_bonus = rehabilitation_bonus_max_config
      progress = clean_streams.to_f / rehab_streams
      (max_bonus * progress).clamp(0.0, max_bonus)
    end

    # Config from DB
    def self.rehabilitation_streams_config
      SignalConfiguration.value_for("trust_index", "default", "rehabilitation_streams").to_f
    rescue SignalConfiguration::ConfigurationMissing
      15.0
    end

    def self.rehabilitation_bonus_max_config
      SignalConfiguration.value_for("trust_index", "default", "rehabilitation_bonus_max").to_f
    rescue SignalConfiguration::ConfigurationMissing
      15.0
    end

    def self.incident_threshold_config
      SignalConfiguration.value_for("trust_index", "default", "incident_threshold").to_f
    rescue SignalConfiguration::ConfigurationMissing
      40.0
    end

    def self.population_mean_config
      SignalConfiguration.value_for("trust_index", "default", "population_mean").to_f
    rescue SignalConfiguration::ConfigurationMissing
      65.0
    end

    private_class_method :find_latest_incident, :count_clean_streams, :bot_raid_victim?,
      :calculate_bonus, :rehabilitation_streams_config, :rehabilitation_bonus_max_config,
      :incident_threshold_config, :population_mean_config
  end
end
