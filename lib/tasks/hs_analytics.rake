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
