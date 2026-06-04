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
  # Chat-active wins for usernames present in both sources (finer grain). Lurkers fill
  # the gap that ViewerMetrics-style "% of audience watched <Nmin vs >Nmin" semantics
  # need for the silent majority.
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
      results = chat_data.map { |username, rec| build_result(username, rec, source: "chat") }
      return results unless include_lurkers

      chat_users = chat_data.keys.to_set
      sweep_data = sweep_first_last_seen
      sweep_data.each do |username, rec|
        next if chat_users.include?(username)
        results << build_result(username, rec, source: "sweep")
      end
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
      return {} if snapshots.empty?

      acc = {}
      snapshots.each do |timestamp, logins|
        Array(logins).each do |login|
          rec = acc[login] ||= {
            first_seen_at: timestamp,
            last_seen_at: timestamp,
            observation_count: 0
          }
          rec[:first_seen_at] = timestamp if timestamp < rec[:first_seen_at]
          rec[:last_seen_at] = timestamp if timestamp > rec[:last_seen_at]
          rec[:observation_count] += 1
        end
      end
      acc
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
