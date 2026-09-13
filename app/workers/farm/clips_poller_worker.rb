# frozen_string_literal: true

module Farm
  # EPIC FARM T-F2: polls the trailing-window clip pool of each farmed category via
  # Helix /clips?game_id (cursor pagination) and upserts FarmClip rows + a view
  # snapshot per sighting (velocity source). Cron every 3h; Helix stays Sidekiq-side
  # (repo convention — HelixClient retry sleep() must never block Puma).
  #
  # Category filter is STRICT game_id (never ILIKE / name matching): the PUBG test
  # run leaked Dota/JC via broadcaster fetches and PUBG MOBILE via name matching.
  class ClipsPollerWorker
    include Sidekiq::Worker
    sidekiq_options queue: :monitoring, retry: 2

    # Fallback only — PUBG, verified live 2026-09-02. Used when FarmCaptureCategory is empty (a
    # fresh environment where the seeder has not run), never as the operating configuration.
    FALLBACK_CATEGORIES = %w[493057].freeze
    WINDOW = 26.hours # trailing window; overlaps the 3h cron so nothing is missed
    PAGES = 5
    PAGE_SIZE = 100

    def perform
      return unless Flipper.enabled?(:farm_clips_poller)

      game_ids.each { |game_id| poll_category(game_id) }
    end

    private

    # The chat side of the farm has walked four categories from FarmCaptureCategory since T-F1
    # while this worker stayed hard-coded to one, so the clip pool covered a quarter of what we
    # were listening to and none of the channels the product actually watches. Same table, same
    # enabled flag, one source of truth for what "a farmed category" means.
    def game_ids
      ids = FarmCaptureCategory.where(enabled: true).pluck(:game_id).map(&:to_s).reject(&:blank?)
      return ids if ids.any?

      Rails.logger.warn("Farm::ClipsPollerWorker: no enabled FarmCaptureCategory — falling back to #{FALLBACK_CATEGORIES.join(',')}")
      FALLBACK_CATEGORIES
    end

    def poll_category(game_id)
      helix = Twitch::HelixClient.new
      now = Time.current
      window_start = WINDOW.ago(now) # fixed per run: Helix cursors are bound to their query params (CR Nit-1)
      cursor = nil

      PAGES.times do
        page = helix.get_clips_by_game(
          game_id: game_id, first: PAGE_SIZE, after: cursor,
          started_at: window_start, ended_at: now
        )
        page["data"].each { |clip| upsert_clip(clip, game_id, now) }
        cursor = page["cursor"]
        break if cursor.blank? || page["data"].empty?
      end
    end

    def upsert_clip(attrs, game_id, now)
      # Defense-in-depth: Helix already filters by game_id, but a clip row carries its
      # own game_id — drop anything foreign instead of ever mixing categories.
      return if attrs["game_id"].present? && attrs["game_id"] != game_id

      clip = FarmClip.find_or_initialize_by(clip_id: attrs["id"])
      clip.assign_attributes(
        game_id: game_id,
        broadcaster_twitch_id: attrs["broadcaster_id"].to_s,
        broadcaster_name: attrs["broadcaster_name"],
        creator_twitch_id: attrs["creator_id"].to_s.presence,
        creator_name: attrs["creator_name"],
        title: attrs["title"],
        language: attrs["language"],
        url: attrs["url"],
        video_id: attrs["video_id"].presence,
        thumbnail_url: attrs["thumbnail_url"],
        view_count: attrs["view_count"].to_i,
        duration: attrs["duration"]&.to_f,
        vod_offset: attrs["vod_offset"],
        is_featured: attrs["is_featured"] == true,
        twitch_created_at: attrs["created_at"],
        last_seen_at: now
      )
      clip.first_seen_at ||= now
      clip.save!
      record_snapshot(clip, attrs["view_count"].to_i, now)
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique => e
      Rails.logger.warn("Farm::ClipsPollerWorker: skip clip #{attrs['id'].inspect}: #{e.message}")
    end

    # Snapshot idempotency for Sidekiq retries (CR Nit-3): a partial-failure retry re-walks
    # clips it already snapshotted seconds ago — a same-cycle duplicate adds only noise to the
    # velocity series, so skip when the freshest snapshot is younger than the guard window.
    SNAPSHOT_MIN_GAP = 30.minutes

    def record_snapshot(clip, view_count, now)
      return if clip.view_snapshots.exists?(captured_at: SNAPSHOT_MIN_GAP.ago(now)..)

      clip.view_snapshots.create!(view_count: view_count, captured_at: now)
    end
  end
end
