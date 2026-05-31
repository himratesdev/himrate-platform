# frozen_string_literal: true

module Streams
  # BUG-251.40 Phase C — operational cleanup of fused + ghosted open Stream rows.
  #
  # 2026-05-31 staging audit found 521 open Streams (ended_at IS NULL) accumulated from
  # months of MonitoredLiveDetectorWorker doing channel-id-only identity checks. Of those:
  #   - 224 FUSE  (Helix shows a different per-broadcast `id` than our row's twitch_stream_id)
  #   - 284 GHOST (Helix offline for >12h, our row never debounced-closed)
  #   - 13  OK    (long-running channels — esports, music, real 24/7 streams)
  #
  # Phase A2 (PR #237) fixes the open-side path going forward — on the next MLD cycle a
  # fused channel triggers close-and-reopen via StreamOnlineWorker. But the 521 backlog
  # rows would only converge via the slow per-channel cron-driven path AND the close
  # path goes through :signals queue which currently has a 1.1M historical backlog.
  # This service is the operational scalpel: enumerate fused + ghosted rows, close each
  # via StreamOfflineWorker.new.perform (synchronous) so they're finalized in minutes
  # rather than hours/days.
  #
  # USAGE:
  #   Streams::LifecycleAudit.new(dry_run: true).call       # preview
  #   Streams::LifecycleAudit.new(dry_run: false).call      # apply
  #
  # OR via rake (preferred — wraps logging + boolean coercion):
  #   bin/rails streams:audit                                # always read-only
  #   bin/rails streams:cleanup_fuse_and_ghost               # default dry_run=true
  #   bin/rails streams:cleanup_fuse_and_ghost[false]        # apply
  class LifecycleAudit
    # Streams younger than this are likely legit ongoing broadcasts — leave alone.
    # Real-world streamers rarely stream >12h continuously; 24h+ is almost always a
    # broadcaster who reconnected with a new broadcast id we never detected.
    DEFAULT_MIN_AGE_HOURS = 12

    # Throttle close operations to avoid storming downstream pipelines
    # (StreamOfflineWorker enqueues BotScoringWorker + PostStreamWorker per close).
    INTER_CLOSE_SLEEP_SEC = 0.1

    def initialize(dry_run: true, min_age_hours: DEFAULT_MIN_AGE_HOURS, logger: Rails.logger)
      @dry_run = dry_run
      @min_age_hours = min_age_hours
      @logger = logger
    end

    # Read-only — classify and print summary.
    def audit_only
      data = classify
      print_summary(data)
      data
    end

    # Classify + (unless dry_run) finalize fuse + ghost rows.
    # OK rows are left alone (real ongoing broadcasts).
    def call
      data = classify
      print_summary(data)

      if @dry_run
        @logger.info("Streams::LifecycleAudit: dry_run=true — no rows closed. Re-run with dry_run=false to apply.")
        return data
      end

      to_close = data[:fuse] + data[:ghost]
      @logger.info("Streams::LifecycleAudit: closing #{to_close.size} rows (#{data[:fuse].size} fuse + #{data[:ghost].size} ghost)")
      close_all(to_close)
      data
    end

    private

    # Returns { fuse: [...], ghost: [...], ok: [...] }. Each item is a Hash with
    # channel_id / twitch_id / login / stream_id / our_tws / (for fuse) helix info.
    def classify
      candidates = Stream.where(ended_at: nil)
                         .where("started_at < ?", @min_age_hours.hours.ago)
                         .joins(:channel)
                         .pluck("channels.twitch_id", "channels.id", "channels.login",
                                "streams.id", "streams.twitch_stream_id")

      live_by_twitch_id = fetch_live_streams(candidates.map(&:first).compact.uniq)

      data = { fuse: [], ghost: [], ok: [] }
      candidates.each do |twitch_id, channel_id, login, stream_id, our_tws|
        helix = live_by_twitch_id[twitch_id]
        if helix.nil?
          data[:ghost] << { channel_id: channel_id, twitch_id: twitch_id, login: login, stream_id: stream_id, our_tws: our_tws }
        elsif our_tws.present? && our_tws == helix["id"]
          data[:ok] << { channel_id: channel_id, twitch_id: twitch_id, login: login, stream_id: stream_id, our_tws: our_tws }
        else
          data[:fuse] << {
            channel_id: channel_id, twitch_id: twitch_id, login: login, stream_id: stream_id, our_tws: our_tws,
            helix_id: helix["id"], helix_started: helix["started_at"], helix_game: helix["game_name"]
          }
        end
      end
      data
    end

    # Mirror MonitoredLiveDetectorWorker's batching contract: skip-on-batch-fail (no false
    # offline). Partial failures are treated as "no info" — those channels would land in
    # ghost set but we conservatively log + skip them so we don't close legit live broadcasts.
    def fetch_live_streams(twitch_ids)
      return {} if twitch_ids.empty?

      live = {}
      failed_batches = 0
      twitch_ids.each_slice(MonitoredLiveDetectorWorker::HELIX_BATCH_SIZE) do |batch|
        data = helix.get_streams(user_ids: batch)
        if data.nil?
          failed_batches += 1
          next
        end
        data.each { |s| live[s["user_id"]] = s }
      end

      if failed_batches.positive?
        @logger.warn("Streams::LifecycleAudit: #{failed_batches} Helix sub-batch(es) failed — channels in those batches will appear as GHOST candidates. Re-run after Helix recovers.")
      end
      live
    end

    def close_all(items)
      items.each_with_index do |item, idx|
        StreamOfflineWorker.new.perform(
          { "broadcaster_user_id" => item[:twitch_id], "broadcaster_user_login" => item[:login] },
          "lifecycle_audit"
        )
        sleep INTER_CLOSE_SLEEP_SEC
        @logger.info("Streams::LifecycleAudit: closed #{idx + 1}/#{items.size} — ##{item[:login]} stream=#{item[:stream_id]}") if ((idx + 1) % 25).zero?
      end
      @logger.info("Streams::LifecycleAudit: closed #{items.size} rows total")
    end

    def print_summary(data)
      @logger.info("Streams::LifecycleAudit: classified open streams older than #{@min_age_hours}h:")
      @logger.info("  FUSE  (Helix live, twitch_stream_id mismatch): #{data[:fuse].size}")
      @logger.info("  GHOST (Helix offline, our row open):           #{data[:ghost].size}")
      @logger.info("  OK    (continuation — leave alone):            #{data[:ok].size}")

      sample_fuse = data[:fuse].first(5)
      sample_ghost = data[:ghost].first(5)
      sample_fuse.each { |f| @logger.info("  FUSE  ##{f[:login]} our_tws=#{f[:our_tws].inspect} helix_id=#{f[:helix_id]} game=#{f[:helix_game]}") }
      sample_ghost.each { |g| @logger.info("  GHOST ##{g[:login]} our_tws=#{g[:our_tws].inspect}") }
    end

    def helix
      @helix ||= Twitch::HelixClient.new
    end
  end
end
