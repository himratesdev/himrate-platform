# frozen_string_literal: true

# TASK-038 FR-035: Recommendation effectiveness analytics.
# For each dismissed recommendation, compute HS delta 30d after dismissal.
# Output: CSV per rule_id with mean/median/count. For product team calibration.
# Run monthly (cron) or manually: `rails hs:analyze_recommendation_effectiveness`

namespace :hs do
  desc "Analyze recommendation effectiveness (dismissed → HS delta over 30d)"
  task analyze_recommendation_effectiveness: :environment do
    require "csv"

    output_path = Rails.root.join("tmp/hs_rec_effectiveness_#{Date.current.iso8601}.csv")
    cutoff = 30.days.ago # only analyze dismissals older than 30 days (sufficient observation window)

    dismissals = DismissedRecommendation.where("dismissed_at < ?", cutoff)

    results = Hash.new { |h, k| h[k] = [] }

    dismissals.find_each do |dr|
      hs_at = HealthScore.where(channel_id: dr.channel_id)
        .where("calculated_at <= ?", dr.dismissed_at)
        .order(calculated_at: :desc)
        .pick(:health_score)

      hs_after = HealthScore.where(channel_id: dr.channel_id)
        .where("calculated_at >= ?", dr.dismissed_at + 30.days)
        .order(:calculated_at)
        .pick(:health_score)

      next unless hs_at && hs_after

      delta = (hs_after.to_f - hs_at.to_f).round(2)
      results[dr.rule_id] << delta
    end

    CSV.open(output_path, "wb") do |csv|
      csv << %w[rule_id count mean_delta median_delta min_delta max_delta]
      results.each do |rule_id, deltas|
        next if deltas.empty?

        sorted = deltas.sort
        mean = (deltas.sum / deltas.size).round(2)
        median = sorted[sorted.size / 2].round(2)
        csv << [ rule_id, deltas.size, mean, median, sorted.first.round(2), sorted.last.round(2) ]
      end
    end

    puts "Report written: #{output_path}"
    puts "Total rules analyzed: #{results.keys.size}"
    results.each do |rule_id, deltas|
      puts "  #{rule_id}: n=#{deltas.size}, mean_delta=#{(deltas.sum / deltas.size).round(2)}" if deltas.any?
    end
  end

  desc "Backfill hs_tier_change_events from existing HealthScore history"
  task backfill_tier_change_events: :environment do
    total = 0
    created = 0

    Channel.find_each do |channel|
      history = HealthScore
        .where(channel_id: channel.id)
        .where.not(hs_classification: nil)
        .order(:calculated_at)
        .to_a

      next if history.size < 2

      previous = history.first
      history.drop(1).each do |current|
        total += 1
        next if previous.hs_classification == current.hs_classification

        HsTierChangeEvent.find_or_create_by!(
          channel_id: channel.id,
          stream_id: current.stream_id,
          occurred_at: current.calculated_at,
          event_type: "tier_change"
        ) do |event|
          event.from_tier = previous.hs_classification
          event.to_tier = current.hs_classification
          event.hs_before = previous.health_score
          event.hs_after = current.health_score
          event.metadata = {
            delta: (current.health_score.to_f - previous.health_score.to_f).round(2),
            backfilled: true
          }
        end
        created += 1
        previous = current
      end
    end

    puts "Backfill: scanned #{total} transitions, created #{created} tier_change_events"
  end

  desc "Backfill rehabilitation_penalty_events from TrustIndexHistory"
  task backfill_rehabilitation_events: :environment do
    total = 0
    created = 0
    resolved = 0

    Channel.find_each do |channel|
      history = TrustIndexHistory
        .where(channel_id: channel.id)
        .order(:calculated_at)
        .to_a
      next if history.empty?

      previous_ti = nil
      active_event = nil

      history.each do |rec|
        total += 1
        current_ti = rec.trust_index_score.to_f

        if previous_ti && previous_ti >= 50 && current_ti < 50 && active_event.nil?
          initial_penalty = [ 50 - current_ti, 0.01 ].max.round(2)
          active_event = RehabilitationPenaltyEvent.find_or_create_by!(
            channel_id: channel.id,
            applied_at: rec.calculated_at
          ) do |event|
            event.applied_stream_id = rec.stream_id
            event.initial_penalty = initial_penalty
            event.required_clean_streams = 15
          end
          created += 1
        elsif active_event && current_ti >= 50
          # Check if cumulative clean streams reached threshold
          clean = TrustIndexHistory
            .where(channel_id: channel.id)
            .where("calculated_at > ? AND calculated_at <= ?", active_event.applied_at, rec.calculated_at)
            .where("trust_index_score >= ?", 50)
            .distinct
            .count(:stream_id)

          if clean >= active_event.required_clean_streams
            active_event.update!(resolved_at: rec.calculated_at, clean_streams_at_resolve: clean)
            resolved += 1
            active_event = nil
          end
        end

        previous_ti = current_ti
      end
    end

    puts "Backfill: scanned #{total} TI records, created #{created} penalty events, resolved #{resolved}"
  end

  desc "Report events volume for monitoring"
  task events_volume_report: :environment do
    puts "hs_tier_change_events total: #{HsTierChangeEvent.count}"
    puts "  tier_changes: #{HsTierChangeEvent.tier_changes.count}"
    puts "  category_changes: #{HsTierChangeEvent.category_changes.count}"
    puts "rehabilitation_penalty_events total: #{RehabilitationPenaltyEvent.count}"
    puts "  active: #{RehabilitationPenaltyEvent.active.count}"
    puts "dismissed_recommendations total: #{DismissedRecommendation.count}"

    if HsTierChangeEvent.count > 5_000_000
      puts "⚠️  hs_tier_change_events > 5M — consider partitioning by occurred_at"
    end
  end
end
