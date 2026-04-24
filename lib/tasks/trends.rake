# frozen_string_literal: true

# TASK-039 backfill rake tasks.
namespace :trends do
  # FR-046 foundation: backfill qualifying percentile snapshots для existing
  # trust_index_history rows missing snapshots. Iterates batches, idempotent.
  #
  # Usage:
  #   rake trends:backfill_qualifying_percentiles                                  # all missing
  #   rake trends:backfill_qualifying_percentiles[2026-01-01]                      # since date
  #   rake trends:backfill_qualifying_percentiles[2026-01-01,2026-04-01]           # range
  #   rake trends:backfill_qualifying_percentiles[,,true]                          # dry-run preview
  #   rake trends:backfill_qualifying_percentiles[2026-01-01,2026-04-01,true]      # dry-run range
  #
  # CR N-2: dry_run prints count + first 10 stream IDs WITHOUT enqueuing — safer
  # для первого production run на large datasets (preview blast radius).
  #
  # Skip rows already snapshotted (engagement_percentile_at_end IS NOT NULL OR
  # engagement_consistency_percentile_at_end IS NOT NULL — partial fills allowed
  # if HS or Reputation data was missing на момент snapshot, повторный backfill
  # пытается снова).
  desc "Backfill engagement + engagement_consistency percentile snapshots в trust_index_histories"
  task :backfill_qualifying_percentiles, %i[since until dry_run] => :environment do |_t, args|
    since_date = args[:since].present? ? Date.parse(args[:since]).beginning_of_day : nil
    until_date = args[:until].present? ? Date.parse(args[:until]).end_of_day : Time.current
    dry_run = ActiveModel::Type::Boolean.new.cast(args[:dry_run])

    scope = TrustIndexHistory.where.not(stream_id: nil)
    scope = scope.where(calculated_at: since_date..until_date) if since_date
    scope = scope.where(calculated_at: ..until_date) unless since_date

    # Только rows без обоих snapshots — skip уже complete для idempotency
    scope = scope.where(
      "engagement_percentile_at_end IS NULL OR engagement_consistency_percentile_at_end IS NULL"
    )

    total = scope.count

    if dry_run
      puts "[DRY-RUN] Would backfill #{total} TIH rows. Sample stream IDs (first 10):"
      scope.limit(10).pluck(:stream_id).each { |id| puts "  - #{id}" }
      puts "[DRY-RUN] Re-run без 3rd arg для actual enqueue."
      next
    end

    puts "Backfilling #{total} TIH rows..."
    processed = 0
    enqueued = 0

    scope.find_each(batch_size: 500) do |tih|
      Trends::QualifyingPercentileSnapshotWorker.perform_async(tih.stream_id)
      enqueued += 1
      processed += 1
      puts "  ... #{processed}/#{total} enqueued" if (processed % 1000).zero?
    end

    puts "Done: #{enqueued} jobs enqueued. Monitor Sidekiq для completion."
  end

  # FR-019 backfill: re-process attributions для existing anomalies без них.
  # Enqueues Trends::AnomalyAttributionWorker per anomaly. Idempotent — Pipeline
  # UPSERTs (не создаёт duplicates). Useful после adding new adapter OR
  # correcting stale attributions.
  #
  # Usage:
  #   rake trends:reprocess_attributions                              # all missing
  #   rake trends:reprocess_attributions[2026-01-01]                  # since date
  #   rake trends:reprocess_attributions[2026-01-01,2026-04-01]       # range
  #   rake trends:reprocess_attributions[,,true]                      # dry-run preview
  desc "Re-process attribution pipeline для existing anomalies (idempotent UPSERT)"
  task :reprocess_attributions, %i[since until dry_run] => :environment do |_t, args|
    since_date = args[:since].present? ? Date.parse(args[:since]).beginning_of_day : nil
    until_date = args[:until].present? ? Date.parse(args[:until]).end_of_day : Time.current
    dry_run = ActiveModel::Type::Boolean.new.cast(args[:dry_run])

    scope = Anomaly.all
    scope = scope.where(timestamp: since_date..until_date) if since_date
    scope = scope.where(timestamp: ..until_date) unless since_date

    total = scope.count

    if dry_run
      puts "[DRY-RUN] Would re-process #{total} anomalies. Sample IDs (first 10):"
      scope.limit(10).pluck(:id).each { |id| puts "  - #{id}" }
      puts "[DRY-RUN] Re-run без 3rd arg для actual enqueue."
      next
    end

    puts "Re-processing attributions для #{total} anomalies..."
    processed = 0
    enqueued = 0

    scope.find_each(batch_size: 500) do |anomaly|
      Trends::AnomalyAttributionWorker.perform_async(anomaly.id)
      enqueued += 1
      processed += 1
      puts "  ... #{processed}/#{total} enqueued" if (processed % 1000).zero?
    end

    puts "Done: #{enqueued} jobs enqueued."
  end

  # FR-045 backfill: re-aggregate trends_daily_aggregates для channel × date grid.
  # Enqueues Trends::AggregationWorker per (channel_id, date) pair. Worker handles
  # pg_advisory_lock + idempotent UPSERT через DailyBuilder (core + deferred fields).
  #
  # Usage:
  #   rake trends:backfill_aggregates                                        # last 90d, all channels
  #   rake trends:backfill_aggregates[2026-01-01]                            # since date, default until=today
  #   rake trends:backfill_aggregates[2026-01-01,2026-04-01]                 # range
  #   rake trends:backfill_aggregates[2026-01-01,2026-04-01,100]             # channel batch_size (Sidekiq backpressure)
  #   rake trends:backfill_aggregates[,,,true]                               # dry-run preview
  desc "Backfill trends_daily_aggregates для channel × date grid (idempotent via AggregationWorker)"
  task :backfill_aggregates, %i[since until batch_size dry_run] => :environment do |_t, args|
    since_date = args[:since].present? ? Date.parse(args[:since]) : 90.days.ago.to_date
    until_date = args[:until].present? ? Date.parse(args[:until]) : Date.current
    batch_size = args[:batch_size].present? ? args[:batch_size].to_i : 500
    dry_run = ActiveModel::Type::Boolean.new.cast(args[:dry_run])

    total_channels = Channel.count
    date_count = (until_date - since_date).to_i + 1
    total_pairs = total_channels * date_count

    if dry_run
      puts "[DRY-RUN] Would enqueue #{total_pairs} AggregationWorker jobs (#{total_channels} channels × #{date_count} days)."
      puts "[DRY-RUN] Range: #{since_date} .. #{until_date}. Channel sample (first 10):"
      Channel.limit(10).pluck(:id, :login).each { |id, login| puts "  - #{id} (#{login})" }
      puts "[DRY-RUN] Re-run без 4th arg для actual enqueue."
      next
    end

    puts "Backfilling #{total_pairs} (channel × date) pairs for #{since_date} .. #{until_date}..."
    enqueued = 0

    Channel.find_each(batch_size: batch_size) do |channel|
      (since_date..until_date).each do |date|
        Trends::AggregationWorker.perform_async(channel.id, date.to_s)
        enqueued += 1
        puts "  ... #{enqueued}/#{total_pairs} enqueued" if (enqueued % 5000).zero?
      end
    end

    puts "Done: #{enqueued} AggregationWorker jobs enqueued. Monitor Sidekiq queue :signals for completion."
  end

  # FR-045 backfill: recompute follower_ccv_coupling_r для TDA rows где оно NULL.
  # Narrower scope than full backfill_aggregates — exists для edge case когда core
  # aggregates populated но deferred coupling field missed (with_isolation recovery).
  #
  # Usage:
  #   rake trends:backfill_follower_ccv_coupling                          # last 90d, all NULL rows
  #   rake trends:backfill_follower_ccv_coupling[2026-01-01]              # since
  #   rake trends:backfill_follower_ccv_coupling[2026-01-01,2026-04-01]   # range
  #   rake trends:backfill_follower_ccv_coupling[,,true]                  # dry-run preview
  desc "Recompute follower_ccv_coupling_r для trends_daily_aggregates rows с NULL coupling"
  task :backfill_follower_ccv_coupling, %i[since until dry_run] => :environment do |_t, args|
    since_date = args[:since].present? ? Date.parse(args[:since]) : 90.days.ago.to_date
    until_date = args[:until].present? ? Date.parse(args[:until]) : Date.current
    dry_run = ActiveModel::Type::Boolean.new.cast(args[:dry_run])

    scope = TrendsDailyAggregate
      .where(date: since_date..until_date)
      .where(follower_ccv_coupling_r: nil)

    total = scope.count

    if dry_run
      puts "[DRY-RUN] Would recompute follower_ccv_coupling_r для #{total} TDA rows в #{since_date} .. #{until_date}."
      puts "[DRY-RUN] Sample rows (first 10):"
      scope.limit(10).pluck(:channel_id, :date).each { |cid, d| puts "  - channel=#{cid} date=#{d}" }
      puts "[DRY-RUN] Re-run без 3rd arg для actual compute."
      next
    end

    puts "Recomputing follower_ccv_coupling_r для #{total} TDA rows..."
    processed = 0
    updated = 0

    scope.find_each(batch_size: 500) do |tda|
      processed += 1
      result = Trends::Analysis::FollowerCcvCouplingTimeline.call(
        channel_id: tda.channel_id, from: tda.date, to: tda.date
      )
      r_value = result[:timeline].first&.dig(:r)
      next if r_value.nil?

      TrendsDailyAggregate
        .where(channel_id: tda.channel_id, date: tda.date)
        .update_all(follower_ccv_coupling_r: r_value)
      updated += 1
      puts "  ... #{processed}/#{total} processed (#{updated} updated)" if (processed % 1000).zero?
    end

    puts "Done: #{updated}/#{processed} rows updated with computed coupling (rest skipped: insufficient follower/ccv history)."
  end

  # FR-045 timezone detection: populate channels.timezone используя language distribution
  # Stream rows. Default 'UTC' (per migration 20260419100004). Only overwrites когда есть
  # dominant language signal — conservative, better UTC чем wrong guess.
  #
  # Usage:
  #   rake trends:detect_timezones          # all channels с timezone='UTC'
  #   rake trends:detect_timezones[true]    # dry-run preview
  desc "Detect channels.timezone по dominant stream language (conservative fallback UTC)"
  task :detect_timezones, [ :dry_run ] => :environment do |_t, args|
    dry_run = ActiveModel::Type::Boolean.new.cast(args[:dry_run])

    min_streams = SignalConfiguration
      .value_for("trends", "timezone_detection", "min_streams_required")
      .to_i
    dominance_threshold = SignalConfiguration
      .value_for("trends", "timezone_detection", "dominance_threshold")
      .to_f

    scope = Channel.where(timezone: "UTC")
    total = scope.count

    puts "#{dry_run ? '[DRY-RUN] ' : ''}Scanning #{total} UTC-default channels for timezone detection..."
    puts "Config: min_streams=#{min_streams}, dominance_threshold=#{dominance_threshold}"

    updated = 0
    skipped_insufficient = 0
    skipped_ambiguous = 0

    scope.find_each(batch_size: 500) do |channel|
      lang_counts = Stream
        .where(channel_id: channel.id)
        .where.not(language: [ nil, "" ])
        .group(:language)
        .count

      stream_total = lang_counts.values.sum
      if stream_total < min_streams
        skipped_insufficient += 1
        next
      end

      dominant_lang, dominant_count = lang_counts.max_by { |_, count| count }
      dominance = dominant_count.to_f / stream_total

      if dominance < dominance_threshold
        skipped_ambiguous += 1
        next
      end

      detected_tz = LANGUAGE_TO_TIMEZONE[dominant_lang]
      if detected_tz.nil?
        skipped_ambiguous += 1
        next
      end

      if dry_run
        puts "  - channel=#{channel.id} login=#{channel.login} lang=#{dominant_lang} (#{(dominance * 100).round(0)}%) → #{detected_tz}"
      else
        channel.update_column(:timezone, detected_tz)
      end
      updated += 1
    end

    verb = dry_run ? "Would update" : "Updated"
    puts "Done: #{verb} #{updated} channels. Skipped: #{skipped_insufficient} insufficient streams, #{skipped_ambiguous} ambiguous language."
    puts "[DRY-RUN] Re-run без arg для actual update." if dry_run
  end

  # Primary IANA tz для каждого dominant language. Conservative: чем больше
  # language охватывает, тем вероятнее стрим идёт в этом часовом поясе.
  # Ambiguous cases (en, es) → skip (too many possible tz). Добавлять новые mappings
  # по мере накопления data signal.
  LANGUAGE_TO_TIMEZONE = {
    "ru" => "Europe/Moscow",
    "uk" => "Europe/Kyiv",
    "de" => "Europe/Berlin",
    "fr" => "Europe/Paris",
    "it" => "Europe/Rome",
    "es" => "Europe/Madrid",       # ES-Spain dominant; LatAm variants — future когда есть locale signal
    "pt" => "Europe/Lisbon",        # PT-PT; BR variant нужен отдельный streams.region hint
    "pl" => "Europe/Warsaw",
    "tr" => "Europe/Istanbul",
    "nl" => "Europe/Amsterdam",
    "cs" => "Europe/Prague",
    "ja" => "Asia/Tokyo",
    "ko" => "Asia/Seoul",
    "zh-cn" => "Asia/Shanghai",
    "zh-tw" => "Asia/Taipei",
    "th" => "Asia/Bangkok",
    "vi" => "Asia/Ho_Chi_Minh"
    # NOTE: English (en) deliberately absent — слишком много candidate tz (US/UK/AU/CA/NZ/IE).
    # Для EN channels timezone остаётся UTC до introducing explicit region signal.
  }.freeze
end
