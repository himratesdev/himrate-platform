# frozen_string_literal: true

module Farm
  # EPIC FARM T-F1: reconcile the capture set (Farm::CaptureSet) against Helix every cycle.
  #
  # For each enabled FarmCaptureCategory: page GET /streams?game_id=… (+ language allowlist) to
  # the end → the category's live logins. Channels that the bot-detection IRC already holds
  # (monitored + open Stream) are excluded — their chat lands in `chat_messages` and must not be
  # captured twice. Then CaptureSet#sync joins newcomers, parts channels absent 3 sweeps in a
  # row, and treats categories whose paging failed as "no information this cycle".
  #
  # Cost (INGEST-EXPANSION-DESIGN §5.3): PUBG 7 + JC(ru+en) ~10 + CS 13 + Dota 6 pages ≈ 40 Helix
  # requests per cycle, every 2 min → ~20 req/min of the 800/min budget. Helix stays Sidekiq-side
  # (HelixClient retry sleep() must never block Puma).
  class CaptureSetSyncWorker
    include Sidekiq::Job
    sidekiq_options queue: :monitoring, retry: 1

    CYCLE_INTERVAL = 120 # seconds — sidekiq-cron cadence, documented here for reference
    PAGE_SIZE = 100
    MAX_PAGES = 80 # JC all-languages ≈ 57 pages at US-evening peak; ru+en is ~10 — hard guard only

    def perform
      return unless Flipper.enabled?(:farm_capture)

      categories = FarmCaptureCategory.enabled.to_a
      return if categories.empty?

      live = {}
      complete = Set.new
      categories.each do |category|
        logins = page_category(category)
        next if logins.nil? # Helix failed mid-way → category has no information this cycle

        logins.each { |login| live[login] = category.game_id }
        complete << category.game_id
      end

      stats = capture_set.sync(live: live, complete_game_ids: complete, excluded: monitored_live_logins)
      Rails.logger.info(
        "Farm::CaptureSetSyncWorker: live=#{live.size} across #{complete.size}/#{categories.size} categories " \
        "(incomplete: #{(categories.map(&:game_id) - complete.to_a).inspect}) → joined=#{stats.joined} " \
        "parted=#{stats.parted} kept=#{stats.kept} skipped_incomplete=#{stats.skipped_incomplete}"
      )
    end

    private

    # Array of live logins for the category, or nil when any page failed (partial-batch semantics).
    def page_category(category)
      logins = []
      cursor = nil
      MAX_PAGES.times do
        page = helix.get_streams_page(
          game_id: category.game_id, languages: category.language_filter, first: PAGE_SIZE, after: cursor
        )
        if page.nil?
          Rails.logger.warn("Farm::CaptureSetSyncWorker: Helix page failed for #{category.game_name} (#{category.game_id}) — category skipped this cycle")
          return nil
        end

        page["data"].each do |stream|
          # Defense-in-depth: Helix already filters by game_id; drop anything foreign (never mix categories).
          next if stream["game_id"].to_s != category.game_id
          next if stream["viewer_count"].to_i < category.viewer_floor

          login = stream["user_login"].to_s.downcase
          logins << login if login.present?
        end
        cursor = page["cursor"]
        break if cursor.blank? || page["data"].empty?
      end
      logins
    end

    # Channels the bot-detection IRC (bin/irc_monitor) is in right now: monitored + open Stream.
    def monitored_live_logins
      Channel.monitored.active
             .joins(:streams).where(streams: { ended_at: nil })
             .distinct.pluck(:login).map(&:downcase).to_set
    end

    def capture_set
      @capture_set ||= Farm::CaptureSet.new
    end

    def helix
      @helix ||= Twitch::HelixClient.new
    end
  end
end
