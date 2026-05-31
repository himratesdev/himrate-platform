# frozen_string_literal: true

# TASK-023: EventSub stream.online handler.
# TASK-024: IRC JOIN via Redis pub/sub.
# TASK-025: Create Stream record, stream merge logic, enrich via GQL.

class StreamOnlineWorker
  include Sidekiq::Job
  sidekiq_options queue: :signals

  IRC_COMMANDS_CHANNEL = "irc:commands"
  MERGE_GAP_MINUTES = 30

  def perform(event_data)
    broadcaster_id = event_data["broadcaster_user_id"]
    broadcaster_login = event_data["broadcaster_user_login"]
    # BUG-251.40 A2: Twitch's per-broadcast `stream.id` extracted from the payload.
    # Two enqueue sources use different keys: MonitoredLiveDetectorWorker normalises to
    # `stream_id` (our internal convention), EventSub stream.online webhook forwards
    # Twitch's raw `id` (per the EventSub schema). Either resolves to the same logical
    # value. Blank/nil → "legacy or unknown" — see close_stale_if_fused.
    new_twitch_stream_id = (event_data["stream_id"] || event_data["id"]).presence

    Rails.logger.info(
      "StreamOnlineWorker: stream.online for #{broadcaster_login} (#{broadcaster_id}) " \
      "twitch_stream_id=#{new_twitch_stream_id.inspect}"
    )

    channel = find_or_create_channel(broadcaster_id, broadcaster_login)

    # BUG-251.40 A2: detect the FUSE pattern and close the stale row before deciding
    # whether to create a new one. Without this, a channel that ended overnight and
    # restarted as a NEW Twitch broadcast keeps writing today's CCV/chat into yesterday's
    # Stream row (the 2026-05-31 staging audit found 224 such rows). This block is no-op
    # when the existing row already matches new_twitch_stream_id (continuation).
    #
    # Returns the count of rows actually closed — if non-zero, we MUST bypass the
    # merge branch below: merge_or_create_stream would otherwise see the just-closed
    # row (ended_at ≈ now, well inside MERGE_GAP_MINUTES) and re-open it on game_name
    # match, undoing the fuse fix entirely (CR-237 C1).
    fused_closed_count = close_stale_if_fused(channel, new_twitch_stream_id)

    # BUG-251.29: even when DB shows an already-active stream row, idempotently re-publish
    # IRC join. Previously we returned early — leaving IRC out of sync when (a) the existing
    # row was stale (real Twitch session ended without offline reaching us, then channel went
    # live again), or (b) IrcMonitor was restarted mid-session and dropped its in-memory set.
    # IrcMonitor#subscribe is idempotent (returns :already_joined harmlessly).
    if active_stream_exists?(channel, new_twitch_stream_id)
      publish_irc_join(broadcaster_login)
      return
    end

    stream = merge_or_create_stream(channel, event_data, new_twitch_stream_id, allow_merge: fused_closed_count.zero?)

    # TASK-024: Tell IrcMonitor to join this channel's chat
    publish_irc_join(broadcaster_login)

    Rails.logger.info("StreamOnlineWorker: Stream #{stream.id} for ##{broadcaster_login} (merge: #{stream.merge_status})")
  end

  private

  def find_or_create_channel(twitch_id, login)
    Channel.find_or_create_by!(twitch_id: twitch_id) do |c|
      c.login = login
      c.is_monitored = true
    end
  end

  # BUG-251.40 A2: if our channel has an open Stream whose twitch_stream_id does NOT match
  # the incoming broadcast id (NULL legacy rows count as mismatch when we have a non-blank
  # incoming id), close the stale row(s) via StreamOfflineWorker so the new broadcast gets a
  # fresh record. Synchronous (not perform_async) so the close finishes before the merge/create
  # branch below runs — avoids a brief two-open-streams race that StreamMonitor would otherwise
  # widen by writing two CCV snapshots / minute.
  #
  # Returns count of rows closed. Caller uses this to suppress the merge branch (CR-237 C1):
  # otherwise merge_or_create_stream would find the just-closed row as `last_stream` and
  # re-open it on game_name match, undoing the fuse fix.
  #
  # CR-237 I1: close ALL mismatched open rows in a loop, not just the most recent. Real-world
  # legacy data on staging can have >1 open Stream per channel (pre-A1 indexing); we leave none
  # in fused state. StreamOfflineWorker is idempotent — it picks the most-recent open row each
  # call; iterate until the open-row scope is empty (or matches new_twitch_stream_id).
  #
  # CR-237 I2: the synchronous close enqueues BotScoring/PostStream and publishes IRC PART —
  # all idempotent at the receiver. We don't wrap in a transaction because the side effects
  # (Redis publish, Sidekiq enqueue) leak past commit boundaries anyway; instead the receivers
  # tolerate replay. On Sidekiq retry of this whole perform: close_stale_if_fused becomes a
  # no-op (rows already closed), and the create/merge runs against the fresh state.
  #
  # No-op if new_twitch_stream_id is blank (we have no Helix id to compare against — preserve
  # legacy idempotency: skip the close, fall back to existing active_stream_exists? check).
  def close_stale_if_fused(channel, new_twitch_stream_id)
    return 0 if new_twitch_stream_id.blank?

    closed = 0
    # Bound the loop — guards against the (impossible-in-practice) case of new rows being
    # created mid-loop. Real ceiling is ~5 (largest legacy duplicate count observed).
    10.times do
      stale = channel.streams
                     .where(ended_at: nil)
                     .where("twitch_stream_id IS NULL OR twitch_stream_id != ?", new_twitch_stream_id)
                     .order(started_at: :desc)
                     .first
      break if stale.nil?

      Rails.logger.warn(
        "StreamOnlineWorker: closing stale stream #{stale.id} (twitch_stream_id=#{stale.twitch_stream_id.inspect}) " \
        "before opening new broadcast #{new_twitch_stream_id} for ##{channel.login}"
      )
      StreamOfflineWorker.new.perform(
        { "broadcaster_user_id" => channel.twitch_id, "broadcaster_user_login" => channel.login },
        "fuse_replaced"
      )
      closed += 1
    end
    Rails.logger.warn("StreamOnlineWorker: closed #{closed} stale stream(s) for ##{channel.login}") if closed > 1
    closed
  end

  # BUG-251.40 A2: idempotency now keyed by (channel, new_twitch_stream_id) instead of
  # just channel. When new_twitch_stream_id is blank (legacy EventSub payload without
  # `id` — rare path), fall back to channel-scoped exists? for backward compat.
  def active_stream_exists?(channel, new_twitch_stream_id)
    scope = channel.streams.where(ended_at: nil)
    scope = scope.where(twitch_stream_id: new_twitch_stream_id) if new_twitch_stream_id.present?
    exists = scope.exists?
    Rails.logger.info(
      "StreamOnlineWorker: active stream already exists for ##{channel.login} " \
      "(twitch_stream_id=#{new_twitch_stream_id.inspect}), publishing IRC join idempotently"
    ) if exists
    exists
  end

  def merge_or_create_stream(channel, event_data, new_twitch_stream_id, allow_merge: true)
    # EventSub stream.online does NOT contain category_name/title — fetch from GQL first
    metadata = fetch_metadata(channel.login)
    game_name = metadata&.dig(:game_name)
    title = metadata&.dig(:title)
    language = metadata&.dig(:language)

    # CR-237 C1: when allow_merge=false (fuse path just closed a stale row), skip the
    # merge branch entirely. Otherwise the merge query finds the just-closed-by-fuse row
    # as `last_stream` (ended_at ≈ now, well inside MERGE_GAP_MINUTES) and on game_name
    # match re-opens it — undoing the fuse fix and producing incoherent post-stream
    # artifacts (BotScoring/PostStream were already enqueued for that row).
    last_stream = allow_merge ? channel.streams.where.not(ended_at: nil).order(ended_at: :desc).first : nil
    if last_stream && last_stream.ended_at > MERGE_GAP_MINUTES.minutes.ago && merge_game_match?(game_name, last_stream.game_name)
      # TASK-033 FR-004: Track part boundaries for TI Divergence detection
      last_ti = TrustIndexHistory.where(stream_id: last_stream.id)
                                 .order(calculated_at: :desc)
                                 .first
      boundary = {
        ended_at: last_stream.ended_at.iso8601,
        ti_score: last_ti&.trust_index_score&.to_f,
        erv_percent: last_ti&.erv_percent&.to_f,
        part_number: last_stream.merged_parts_count
      }
      # BUG-251.40 A2: refresh twitch_stream_id to the latest broadcast id on merge.
      # Twitch assigns a NEW per-broadcast id even for "resume" within MERGE_GAP_MINUTES;
      # the merged row should carry the LATEST id so MonitoredLiveDetector's continuation
      # check (helix.id == row.twitch_stream_id) matches on subsequent cycles.
      last_stream.update!(
        ended_at: nil,
        twitch_stream_id: new_twitch_stream_id,
        merge_status: "merged",
        merged_parts_count: last_stream.merged_parts_count + 1,
        part_boundaries: (last_stream.part_boundaries || []) + [ boundary ]
      )
      Rails.logger.info("StreamOnlineWorker: merged with previous stream #{last_stream.id} (parts: #{last_stream.merged_parts_count}, twitch_stream_id=#{new_twitch_stream_id.inspect})")
      last_stream
    else
      Stream.create!(
        channel: channel,
        started_at: event_data["started_at"] || Time.current,
        twitch_stream_id: new_twitch_stream_id,
        title: title,
        game_name: game_name,
        language: language
      )
    end
  end

  # TASK-033 FR-004: nil game_name fallback — GQL failure should not break merge.
  # Both nil = merge (benefit of doubt for reconnection).
  def merge_game_match?(current_game, previous_game)
    return true if current_game.nil? && previous_game.nil?
    return false if current_game.nil? || previous_game.nil?

    current_game == previous_game
  end

  def fetch_metadata(login)
    Twitch::GqlClient.new.stream_metadata(channel_login: login)
  rescue StandardError => e
    Rails.logger.warn("StreamOnlineWorker: GQL metadata failed (#{e.message})")
    nil
  end

  # CR-237 N4: when the FUSE path runs, StreamOfflineWorker publishes a PART for this
  # same login microseconds before this JOIN. Redis pub/sub preserves per-publisher
  # ordering, and IrcMonitor processes commands serially → PART then JOIN reaches the
  # IRC session in order, leaving the channel rejoined. Subtle invariant — break it
  # (e.g. by parallelising the close vs the join) and the channel ends up PART'd with
  # no rejoin, silently dropping chat capture.
  def publish_irc_join(login)
    return unless login.present?

    redis.publish(IRC_COMMANDS_CHANNEL, { action: "join", channel_login: login }.to_json)
  end

  def redis
    @redis ||= Redis.new(url: ENV.fetch("REDIS_URL", "redis://localhost:6379/1"))
  end
end
