# frozen_string_literal: true

module Trust
  # G-4 ViewerMetrics parity (BUG-251.31 PR-B): per-viewer first_seen / last_seen /
  # observation_count per stream. Read-only derivation; no schema migration.
  #
  # ## Hybrid Option C source mix
  #
  # 1. **Chat-active viewers** (sent ≥1 PRIVMSG during the stream): CH `chat_messages`
  #    MIN/MAX(timestamp) per username. Message-grain resolution. Cheap after PR #273
  #    bloom_filter index on stream_id (p95 50–200ms per stream).
  # 2. **Lurkers** (in `chatters_snapshots.viewer_logins` JSONB union but no chat msgs):
  #    PG snapshot rows for the stream → first snapshot login appears in = first_seen,
  #    last snapshot login appears in = last_seen. Minute-grain (snapshot cadence).
  #
  # For usernames present in BOTH sources the result is a HYBRID: `first_seen_at` =
  # MIN(chat.first, sweep.first), `last_seen_at` = MAX(chat.last, sweep.last),
  # `observation_count` = chat.privmsgs + sweep.snapshots, `source = "chat+sweep"`.
  # This captures the silent-tail-before-first-msg and silent-tail-after-last-msg
  # presence portions for chat-active lurkers (someone who lurks 30 min, types 1 msg,
  # then lurks 30 more min) — without it, `first_seen_at` would be the first PRIVMSG
  # and the silent presence span would be invisible to the "% watched <Nmin" callers.
  # Chat-only (no sweep) and sweep-only (no chat) entries keep their respective
  # source label.
  #
  # ## Why this layer (vs persisting per-viewer rows)
  #
  # Per the G-4 design (`_tasks/BUG-251.31-ViewerMetrics-parity/G-4-firstSeen-lastSeen-design.md`):
  #
  # - Stream-end summary / brand-side BAA reads are inherently per-stream (not per-viewer
  #   cross-stream). Computing on demand is cheaper than a permanent write path.
  # - Reuses existing storage (CH chat_messages from PR 1e-A, PG chatters_snapshots.viewer_logins
  #   from PR #272 / PR-A3). No new schema, no new retention policy, no new worker.
  # - Cross-stream loyalty queries (which would justify a persisted
  #   `viewer_session_presences` table) are a Phase-2 surface; when that lands we add
  #   the table THEN.
  #
  # ## Use cases enabled
  #
  # - Stream-end retention summary: "% of audience watched <5min vs >75% of stream"
  # - Anomaly detection: "sudden burst at minute 12, gone by minute 14" raid signature
  # - MLFE features: `avg_first_seen_offset`, `viewer_duration_p50`, …
  # - Brand-side BAA impression attribution (Phase 2 surface)
  #
  # ## Refs
  #
  # - `_tasks/BUG-251.31-ViewerMetrics-parity/G-4-firstSeen-lastSeen-design.md` (design)
  # - `_tasks/BUG-251.31-ViewerMetrics-parity/G-4-impl-Option-C.md` (this implementation)
  # - PR #272 PR-A3 (`viewer_logins` persistence — enables lurker side)
  # - PR #273 Phase 6 M PR-A (bloom_filter idx_stream_id — makes CH side cheap)
  class ViewerSessionPresences
    Result = Struct.new(
      :username,
      :first_seen_at,
      :last_seen_at,
      :observation_count,
      :source,
      :duration_seconds,
      keyword_init: true
    )

    # @param stream [Stream]
    # @param include_lurkers [Boolean] true → merge PG snapshot data (lurkers fill).
    #   false → chat-active only (cheaper; ~50–200ms typical).
    # @return [Array<Result>] one entry per unique viewer in scope
    def self.for_stream(stream, include_lurkers: true)
      new(stream).call(include_lurkers: include_lurkers)
    end

    def initialize(stream)
      @stream = stream
    end

    def call(include_lurkers:)
      chat_data = chat_first_last_seen
      return chat_data.map { |username, rec| build_result(username, rec, source: "chat") } unless include_lurkers

      merge_with_lurkers(chat_data, sweep_first_last_seen)
    end

    # Hybrid merge: widen the [first_seen, last_seen] interval to OUTER bound across both
    # sources for chat-active users who ALSO appear in lurker snapshots. Otherwise
    # "% of audience watched <Nmin" undercounts the silent-tail-before-first-msg and
    # silent-tail-after-last-msg portions. observation_count = chat + sweep so the field
    # semantically reads "total observations" (privmsgs + snapshot appearances). CR iter-2 N1.
    def merge_with_lurkers(chat_data, sweep_data)
      results = chat_data.map do |username, chat_rec|
        sweep_rec = sweep_data.delete(username)
        merged = merge_chat_and_sweep(chat_rec, sweep_rec)
        build_result(username, merged, source: sweep_rec ? "chat+sweep" : "chat")
      end
      sweep_data.each { |username, sweep_rec| results << build_result(username, sweep_rec, source: "sweep") }
      results
    end

    private

    attr_reader :stream

    # Returns { username => { first_seen_at:, last_seen_at:, observation_count: } }
    # for users who sent ≥1 PRIVMSG during the stream. Uses CH bloom_filter index path.
    def chat_first_last_seen
      Clickhouse::ChatQueries.viewer_first_last_seen_per_stream(stream.id)
    end

    # Returns { username => { first_seen_at:, last_seen_at:, observation_count: } }
    # derived from chatters_snapshots.viewer_logins JSONB timeline. observation_count
    # = number of snapshots the username appeared in (minute-grain cadence).
    def sweep_first_last_seen
      snapshots = ChattersSnapshot
        .where(stream_id: stream.id)
        .where.not(viewer_logins: nil)
        .order(:timestamp)
        .pluck(:timestamp, :viewer_logins)
      acc = {}
      snapshots.each do |timestamp, logins|
        Array(logins).each { |login| accumulate_login(acc, login, timestamp) }
      end
      acc
    end

    def accumulate_login(acc, login, timestamp)
      rec = acc[login] ||= { first_seen_at: timestamp, last_seen_at: timestamp, observation_count: 0 }
      rec[:first_seen_at] = timestamp if timestamp < rec[:first_seen_at]
      rec[:last_seen_at] = timestamp if timestamp > rec[:last_seen_at]
      rec[:observation_count] += 1
    end

    def merge_chat_and_sweep(chat_rec, sweep_rec)
      return chat_rec unless sweep_rec
      {
        first_seen_at: [ chat_rec[:first_seen_at], sweep_rec[:first_seen_at] ].min,
        last_seen_at: [ chat_rec[:last_seen_at], sweep_rec[:last_seen_at] ].max,
        observation_count: chat_rec[:observation_count] + sweep_rec[:observation_count]
      }
    end

    def build_result(username, rec, source:)
      duration = (rec[:last_seen_at] - rec[:first_seen_at]).to_i
      Result.new(
        username: username,
        first_seen_at: rec[:first_seen_at],
        last_seen_at: rec[:last_seen_at],
        observation_count: rec[:observation_count],
        source: source,
        duration_seconds: duration
      )
    end
  end
end
