# frozen_string_literal: true

module Farm
  # EPIC FARM T-F1: reconcile the capture set (Farm::CaptureSet) against Helix every cycle.
  #
  # For each enabled FarmCaptureCategory: page GET /streams?game_id=… (+ language allowlist) to
  # the end → the category's live logins. Channels that the bot-detection IRC already holds
  # (monitored + open Stream) are excluded — their chat lands in `chat_messages` and must not be
  # captured twice. Then CaptureSet#sync joins newcomers, parts channels absent 3 sweeps in a
  # row, parts everything whose category was disabled/removed, and treats categories whose paging
  # failed as "no information this cycle". With zero enabled categories the sync still runs — with
  # an empty live set — so every channel is released (CR iter-1 M1: disabling must PART).
  #
  # Cost (INGEST-EXPANSION-DESIGN §5.3): PUBG 7 + JC(ru+en) ~10 + CS 13 + Dota 6 pages ≈ 40 Helix
  # requests per cycle, every 2 min → ~20 req/min of the 800/min budget. Helix stays Sidekiq-side
  # (HelixClient retry sleep() must never block Puma).
  class CaptureSetSyncWorker
    include Sidekiq::Job
    sidekiq_options queue: :monitoring, retry: 1

    CYCLE_INTERVAL = 120 # seconds — sidekiq-cron cadence, documented here for reference
    PAGE_SIZE = 100
    # Hard guard on paging depth. JC all-languages ≈ 57 pages at US-evening peak (ru+en ≈ 10);
    # hitting the guard with a cursor still present = the category is NOT fully seen → it is
    # reported incomplete, never truncated-and-treated-as-complete (CR iter-1 S1).
    MAX_PAGES = 80

    def perform
      return unless Flipper.enabled?(:farm_capture)

      categories = FarmCaptureCategory.enabled.to_a
      configured = categories.map(&:game_id).to_set

      live = {}
      complete = Set.new
      categories.each do |category|
        logins = page_category(category)
        next if logins.nil? # Helix failed / paging exhausted → category has no information this cycle

        logins.each { |login| live[login] = category.game_id }
        complete << category.game_id
      end

      stats = capture_set.sync(live: live, configured_game_ids: configured, complete_game_ids: complete,
                               excluded: monitored_live_logins)
      Rails.logger.info(
        "Farm::CaptureSetSyncWorker: live=#{live.size} across #{complete.size}/#{categories.size} categories " \
        "(incomplete: #{(configured - complete).to_a.inspect}) → joined=#{stats.joined} " \
        "parted=#{stats.parted} kept=#{stats.kept} skipped_incomplete=#{stats.skipped_incomplete}"
      )
    end

    private

    # Array of live logins for the category, or nil when the category was not fully seen
    # (a Helix page failed, or MAX_PAGES ran out with a cursor still present) — partial-batch semantics.
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

        collect_logins(page["data"], category, logins)
        cursor = page["cursor"]
        return logins if cursor.blank? || page["data"].empty?
      end

      Rails.logger.warn("Farm::CaptureSetSyncWorker: MAX_PAGES=#{MAX_PAGES} exhausted for #{category.game_name} (#{category.game_id}) with cursor still present — category skipped this cycle")
      nil
    end

    def collect_logins(streams, category, logins)
      streams.each do |stream|
        # Defense-in-depth: Helix already filters by game_id; drop anything foreign (never mix categories).
        next if stream["game_id"].to_s != category.game_id
        next if stream["viewer_count"].to_i < category.viewer_floor

        login = stream["user_login"].to_s.downcase
        logins << login if login.present?
      end
    end

    # Channels the bot-detection IRC (bin/irc_monitor) is in right now: monitored + active + open Stream
    # (same scope bin/irc_monitor uses to build its own join list — CR iter-1 N2).
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
