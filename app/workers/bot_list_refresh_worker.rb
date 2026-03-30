# frozen_string_literal: true

# TASK-026: Daily refresh of known bot lists from 4 external sources.
# Imports usernames → PostgreSQL (known_bot_lists) + Redis Bloom Filters.
# Cron: 03:00 UTC daily (or self-scheduling chain).

class BotListRefreshWorker
  include Sidekiq::Job
  sidekiq_options queue: :monitoring, retry: 2

  ADAPTERS = [
    BotSources::CommanderRootAdapter,
    BotSources::TwitchInsightsAdapter,
    BotSources::TwitchBotsInfoAdapter,
    BotSources::StreamsChartsAdapter
  ].freeze

  def perform
    return unless Flipper.enabled?(:known_bots)

    service = KnownBotService.new
    source_data = {}
    trend_stats = {}

    ADAPTERS.each do |adapter_class|
      adapter = adapter_class.new
      source = adapter.source_name
      category = adapter.bot_category

      begin
        usernames = adapter.fetch
        Rails.logger.info("BotListRefreshWorker: #{source} → #{usernames.size} bots")

        if usernames.any?
          source_data[source] = usernames
          trend_stats[source] = usernames.size

          # Upsert to PostgreSQL
          upsert_to_db(usernames, source, category)
        else
          Rails.logger.warn("BotListRefreshWorker: #{source} returned 0 bots — keeping old data")
        end
      rescue StandardError => e
        Rails.logger.error("BotListRefreshWorker: #{source} failed (#{e.class}: #{e.message})")
        trend_stats[source] = "error"
      end
    end

    # Rebuild Bloom Filters with all successful sources
    total = service.rebuild_filters(source_data) if source_data.any?

    # FR-015: Trend logging
    log_trend(trend_stats, total)

    # Scheduling via sidekiq-cron (config/initializers/sidekiq_cron.rb)
    # No self-scheduling chain needed — cron ensures daily execution
  end

  private

  def upsert_to_db(usernames, source, category)
    now = Time.current
    batch_size = 5000

    usernames.each_slice(batch_size) do |batch|
      records = batch.map do |username|
        {
          username: username,
          source: source,
          confidence: KnownBotService::CONFIDENCE_SINGLE,
          bot_category: category,
          verified: false,
          added_at: now
        }
      end

      KnownBotList.upsert_all(
        records,
        unique_by: %i[username source],
        update_only: %i[confidence bot_category]
      )
    end
  end

  def log_trend(stats, total)
    Rails.logger.info(
      "BotListRefreshWorker: TREND #{Time.current.strftime("%Y-%m-%d")} — " \
      "total: #{total || "N/A"}, " \
      "per_source: #{stats.map { |s, c| "#{s}=#{c}" }.join(", ")}"
    )
  end
end
