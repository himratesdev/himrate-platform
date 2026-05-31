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
      @failed_batches = 0
    end

    # Read-only — classify and print summary.
    def audit_only
      data = classify
      print_summary(data)
      data
    end

    # Classify + (unless dry_run) finalize fuse + ghost rows.
    # OK rows are left alone (real ongoing broadcasts).
    #
    # CR-238 Important #1: when ANY Helix sub-batch failed during classify, we have
    # incomplete information — a channel in the failed batch shows up as :ghost
    # because Helix didn't say it was live. Closing such rows is exactly the regression
    # BUG-251.19 fixed in the runtime detector. Apply mode REFUSES to proceed when
    # batches failed; operator must re-run after Helix recovers.
    def call
      data = classify
      print_summary(data)

      if @dry_run
        emit("Streams::LifecycleAudit: dry_run=true — no rows closed. Re-run with dry_run=false to apply.")
        return data
      end

      if @failed_batches.positive?
        emit("Streams::LifecycleAudit: REFUSING to apply — #{@failed_batches} Helix sub-batch(es) failed. " \
             "Channels in failed batches show as GHOST candidates but may be legit live. " \
             "Re-run after Helix recovers.")
        return data
      end

      to_close = data[:fuse] + data[:ghost]
      emit("Streams::LifecycleAudit: closing #{to_close.size} rows (#{data[:fuse].size} fuse + #{data[:ghost].size} ghost)")
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
    # ghost set but we conservatively log + (in apply mode) refuse to proceed.
    def fetch_live_streams(twitch_ids)
      return {} if twitch_ids.empty?

      live = {}
      twitch_ids.each_slice(MonitoredLiveDetectorWorker::HELIX_BATCH_SIZE) do |batch|
        data = helix.get_streams(user_ids: batch)
        if data.nil?
          @failed_batches += 1
          next
        end
        data.each { |s| live[s["user_id"]] = s }
      end

      if @failed_batches.positive?
        @logger.warn("Streams::LifecycleAudit: #{@failed_batches} Helix sub-batch(es) failed — channels in those batches will appear as GHOST candidates. Re-run after Helix recovers.")
      end
      live
    end

    # CR-238 Important #2: re-fetch each row before close + verify state hasn't changed
    # (race between classify and close_all — EventSub stream.online could have opened a
    # replacement row while we were preparing to close the fuse). On race detection, skip
    # the close — next audit cycle will catch the real stale row.
    # CR-238 nice #3: per-row rescue keeps a single failed close from aborting the batch.
    # CR-238 nice #4: log every row (verbose but ops-friendly for a one-shot rake).
    def close_all(items)
      results = Hash.new(0)
      items.each_with_index do |item, idx|
        outcome = close_one(item)
        results[outcome] += 1
        emit("Streams::LifecycleAudit: [#{idx + 1}/#{items.size}] ##{item[:login]} stream=#{item[:stream_id][0..7]} → #{outcome}")
        sleep INTER_CLOSE_SLEEP_SEC
      end
      emit("Streams::LifecycleAudit: results — closed=#{results[:closed]} race_replaced=#{results[:replaced]} already_closed=#{results[:already_closed]} state_changed=#{results[:state_changed]} errors=#{results[:error]}")
    end

    # Returns :closed | :gone | :already_closed | :state_changed | :replaced | :error.
    # Race-safe (verifies stream still in target state) + exception-isolated.
    def close_one(item)
      stream = Stream.find_by(id: item[:stream_id])
      return :gone if stream.nil?
      return :already_closed if stream.ended_at.present?
      return :state_changed if stream.twitch_stream_id != item[:our_tws]
      # EventSub may have opened a NEWER stream while we were classifying — StreamOfflineWorker
      # picks `order(started_at: :desc).first` so it would close the WRONG (new) row. Skip.
      if Stream.where(channel_id: stream.channel_id, ended_at: nil).where.not(id: stream.id).exists?
        return :replaced
      end

      StreamOfflineWorker.new.perform(
        { "broadcaster_user_id" => item[:twitch_id], "broadcaster_user_login" => item[:login] },
        "lifecycle_audit"
      )
      :closed
    rescue StandardError => e
      @logger.error("Streams::LifecycleAudit: failed to close ##{item[:login]} stream=#{item[:stream_id]} — #{e.class}: #{e.message.to_s.truncate(120)}")
      :error
    end

    def print_summary(data)
      emit("Streams::LifecycleAudit: classified open streams older than #{@min_age_hours}h:")
      emit("  FUSE  (Helix live, twitch_stream_id mismatch): #{data[:fuse].size}")
      emit("  GHOST (Helix offline, our row open):           #{data[:ghost].size}")
      emit("  OK    (continuation — leave alone):            #{data[:ok].size}")

      data[:fuse].first(5).each { |f| emit("  FUSE  ##{f[:login]} our_tws=#{f[:our_tws].inspect} helix_id=#{f[:helix_id]} game=#{f[:helix_game]}") }
      data[:ghost].first(5).each { |g| emit("  GHOST ##{g[:login]} our_tws=#{g[:our_tws].inspect}") }
    end

    # CR-238 nice #5: also emit to stdout so rake operator sees output without
    # RAILS_LOG_TO_STDOUT=1. logger captures for ops/audit-log retention.
    def emit(line)
      @logger.info(line)
      $stdout.puts(line) if $stdout.tty? || ENV["STREAMS_AUDIT_QUIET"] != "1"
    end

    def helix
      @helix ||= Twitch::HelixClient.new
    end
  end
end
