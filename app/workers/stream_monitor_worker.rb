# frozen_string_literal: true

# TASK-025: Channel Monitoring Orchestrator — periodic polling.
# Tier 1 (every cycle, 60s): CCV + chatters count → snapshots.
# Tier 2 (every 5th cycle, ~5min): ChatRoomState.
# (Predictions/Polls/HypeTrain queries removed 2026-06-04 — Twitch GQL drift
# dropped Channel.{activePredictionEvent, currentPoll, hypeTrainExecution};
# see Twitch::GqlClient method-level comment.)
# Stateless: reads active streams from DB each cycle.

class StreamMonitorWorker
  include Sidekiq::Job
  sidekiq_options queue: :monitoring, retry: 1

  CYCLE_INTERVAL = 60 # seconds — used by sidekiq-cron, documented here for reference
  TIER2_EVERY = 5     # every 5th cycle = ~5 minutes
  GQL_BATCH_SIZE = 35
  # BUG-251.30 CR-iter1 Should-1: poll_tier1 issues 2 ops per login (StreamMetadata +
  # CommunityTab). Split slice so the combined batch stays ≤ MAX_BATCH_SIZE (35) — 17 logins
  # × 2 ops = 34 ops per batch. One round-trip per slice instead of two.
  TIER1_SLICE_SIZE = GQL_BATCH_SIZE / 2
  CHATTERS_WINDOW = 60.minutes # active-chatter window (matches ContextBuilder unique_chatters_60min)
  REDIS_CYCLE_KEY = "monitor:cycle_count"

  def perform
    return unless Flipper.enabled?(:stream_monitor)

    active_streams = Stream.includes(:channel).where(ended_at: nil)
    return if active_streams.empty?

    cycle = increment_cycle

    # Tier 1: CCV + chatters (every cycle)
    poll_tier1(active_streams)

    # Tier 2: ChatRoomState (every 5th cycle)
    poll_tier2(active_streams) if (cycle % TIER2_EVERY).zero?

    Rails.logger.info("StreamMonitorWorker: cycle #{cycle}, #{active_streams.size} streams")
    # Scheduling via sidekiq-cron (config/initializers/sidekiq_cron.rb)
    # No self-scheduling — cron ensures periodic execution
  end

  private

  # === Tier 1: CCV + Chatters ===

  def poll_tier1(streams)
    streams.each_slice(TIER1_SLICE_SIZE) do |batch|
      logins = batch.map { |s| s.channel.login }

      # BUG-251.30 CR-iter1 Should-1: ONE mixed-operation GQL POST per slice (was two —
      # one for CCV + one for CommunityTab). Twitch accepts heterogeneous query batches.
      # Each login contributes [StreamMetadata, CommunityTab] pair (interleaved) so we can
      # demux by position. fetch_ccv_helix_fallback only triggered when the COMBINED batch
      # raises (transport / rescue path); per-item nils in the response array are normal
      # partial failures and demuxed to {} entries.
      ccv_data, chatters_present_data = fetch_ccv_and_chatters_batch(logins)

      # TASK-251.6: chatter activity from captured IRC chat (chat_messages), keyed by
      # stream_id. Active-typer chat_data from IRC is the chatter_ccv_ratio signal #2 input;
      # community_tab presence above feeds AuthRatio signal #1 (distinct: typers vs presence).
      chat_data = fetch_chat_activity(batch)

      batch.each do |stream|
        ccv = ccv_data[stream.channel.login]
        chat = chat_data[stream.id]
        present = chatters_present_data[stream.channel.login]

        save_ccv_snapshot(stream, ccv) if ccv
        save_chatters_snapshot(stream, ccv, chat, present) if (chat || present) && ccv

        # TASK-030: Trigger signal computation after data saved
        SignalComputeWorker.perform_async(stream.id) if ccv || chat || present

        # BUG-251.31 G-3 PR-A2: detect big channel + viewers[] cap hit → enqueue async
        # parallel sweep. Throttled per-channel inside the worker via Redis SETNX (default
        # 5min). Worker itself flag-gated (:big_channel_chatter_sweep) so this enqueue is a
        # no-op until the flag is enabled on staging.
        enqueue_big_channel_sweep_if_needed(stream, present)
      end
    end
  end

  # PR-A2: enqueue Twitch::BigChannelChatterSweepWorker when the single-call CommunityTab
  # is likely sample-capped. Twitch caps `viewers[]` at 100 entries; if we see
  # `viewers_count_present == 100` AND `total_present > 100`, the response was a 100-sample
  # of the chatter pool — running a parallel sweep recovers the long tail. For channels with
  # ≤100 chatters there's nothing to recover, so the gate is exact at the cap.
  def enqueue_big_channel_sweep_if_needed(stream, present)
    return unless present

    viewers_in_response = present[:viewers_count_present].to_i
    total_count = present[:total_present].to_i
    return unless viewers_in_response >= 100 && total_count > viewers_in_response

    Twitch::BigChannelChatterSweepWorker.perform_async(stream.channel.id)
  end

  # BUG-251.30 CR-iter1 Should-1: combined StreamMetadata + CommunityTab batch.
  # Returns [ccv_data, chatters_present_data] keyed by channel login.
  #
  # Note on `total_present`: prefers Twitch's authoritative `chatters["count"]` (which
  # reflects the true total — Twitch returns count even when the `viewers` array is capped
  # at 100). Falls back to sum-of-role-arrays only when `count` is absent (older response
  # shapes). This keeps calibration stable when BUG-251.31 ships viewer pagination.
  def fetch_ccv_and_chatters_batch(logins)
    operations = logins.flat_map do |login|
      [
        { query: Twitch::GqlClient::QUERIES[:stream_metadata], variables: { login: login } },
        { query: Twitch::GqlClient::QUERIES[:community_tab], variables: { login: login } }
      ]
    end

    results = gql.batch(operations) || []
    ccv = {}
    chatters_present = {}

    logins.each_with_index do |login, i|
      stream_metadata = results[i * 2]
      community_tab = results[(i * 2) + 1]

      viewers_count = stream_metadata&.dig("data", "user", "stream", "viewersCount")
      ccv[login] = viewers_count.to_i if viewers_count

      chatters = community_tab&.dig("data", "channel", "chatters")
      next unless chatters

      bcasters = parse_chatters_array(chatters["broadcasters"])
      mods = parse_chatters_array(chatters["moderators"])
      vips = parse_chatters_array(chatters["vips"])
      staff = parse_chatters_array(chatters["staff"])
      viewers = parse_chatters_array(chatters["viewers"])
      sum_present = bcasters.size + mods.size + vips.size + staff.size + viewers.size

      chatters_present[login] = {
        total_present: chatters["count"]&.to_i || sum_present,
        broadcasters_count: bcasters.size,
        moderators_count: mods.size,
        vips_count: vips.size,
        staff_count: staff.size,
        viewers_count_present: viewers.size,
        logins: bcasters + mods + vips + staff + viewers
      }
    end

    [ ccv, chatters_present ]
  rescue Twitch::GqlClient::Error => e
    # execute_batch returns nil-padded results on per-item failures (never raises) — this
    # rescue covers true transport failure of the whole call. Preserve CCV via Helix fallback;
    # community_tab has no Helix equivalent → empty presence map (AuthRatio gracefully reports
    # :no_chatters_present_data via ContextBuilder).
    Rails.logger.warn("StreamMonitorWorker: combined GQL batch failed (#{e.message}), CCV → Helix fallback")
    [ fetch_ccv_helix_fallback(logins), {} ]
  end

  def parse_chatters_array(list)
    return [] unless list.is_a?(Array)

    list.map { |u| u["login"] }.compact
  end

  def fetch_ccv_helix_fallback(logins)
    result = {}
    logins.each_slice(100) do |batch|
      streams = helix.get_streams(user_logins: batch) || []
      streams.each do |s|
        login = s["user_login"]&.downcase
        result[login] = s["viewer_count"].to_i if login
      end
    end
    result
  end

  # TASK-251.6: derive chatter activity from captured IRC chat (chat_messages) within
  # CHATTERS_WINDOW — one grouped query pair per batch (no per-channel GQL calls).
  # GQL chatters_count is integrity-protected (empty server-side). Returns
  # { stream_id => { unique:, total: } } only for streams that had chat in the window.
  # PR 1e-A (2026-05-31): batched chat activity from ClickHouse instead of PG.
  # Same return shape ({ stream_id => { unique:, total: } }) — streams with 0 privmsg
  # in the window are absent from the Hash (matches PG groupby).
  def fetch_chat_activity(streams)
    Clickhouse::ChatQueries.chat_activity_batch(streams.map(&:id), CHATTERS_WINDOW.ago)
  end

  def save_ccv_snapshot(stream, ccv_count)
    CcvSnapshot.create!(
      stream: stream,
      timestamp: Time.current,
      ccv_count: ccv_count
    )
  end

  # BUG-251.30 (extended): persist both active-typer columns (existing semantics) AND
  # new presence columns. Either source may be nil (e.g., community_tab rate-limited but
  # chat captured, or vice versa) — null-safe.
  def save_chatters_snapshot(stream, ccv_count, chat, present = nil)
    unique = chat ? chat[:unique].to_i : 0
    total = chat ? chat[:total].to_i : 0
    auth_ratio = ccv_count.to_i.positive? && unique.positive? ? unique.to_f / ccv_count : nil

    ChattersSnapshot.create!(
      stream: stream,
      timestamp: Time.current,
      unique_chatters_count: unique,
      total_messages_count: total,
      auth_ratio: auth_ratio,
      chatters_present_total: present&.dig(:total_present),
      viewer_logins: present&.dig(:logins) || [],
      broadcasters_count: present&.dig(:broadcasters_count),
      moderators_count: present&.dig(:moderators_count),
      vips_count: present&.dig(:vips_count),
      staff_count: present&.dig(:staff_count),
      viewers_count_present: present&.dig(:viewers_count_present)
    )
  end

  # === Tier 2: ChatRoomState ===
  # Predictions/Polls/HypeTrain calls dropped 2026-06-04 (Twitch GQL field
  # drift — see Twitch::GqlClient). `latest_ccv` lookup removed with them.

  def poll_tier2(streams)
    streams.each do |stream|
      login = stream.channel.login
      update_chat_room_state(stream.channel, login)
    end
  end

  # CPS (Channel Protection Score) calculation deferred to TASK-026+ (Signal Workers).
  # This method stores raw settings; CPS formula applied in trust_index/signals/.
  def update_chat_room_state(channel, login)
    data = gql.chat_room_state(channel_login: login)
    return unless data

    config = channel.channel_protection_config || channel.build_channel_protection_config
    # BUG-251.32: removed deprecated fields from update set (email/phone verification mode +
    # minimum_account_age + restrict_first_time_chatters — Twitch dropped accountVerificationOptions
    # subtype). New consolidated boolean: `verified_account_required` (chatSettings.requireVerifiedAccount).
    # Legacy columns left at their DB defaults (email_verification_required / phone_verification_required /
    # restrict_first_time_chatters: null:false default:false; minimum_account_age_minutes: nullable);
    # they are no longer used by CPS scoring — historical rows readable, new rows untouched.
    config.update!(
      followers_only_duration_min: data[:followers_only_duration_minutes],
      slow_mode_seconds: data[:slow_mode_duration_seconds],
      emote_only_enabled: data[:emote_only_mode] || false,
      subs_only_enabled: data[:subscriber_only_mode] || false,
      verified_account_required: data[:require_verified_account] || false,
      last_checked_at: Time.current
    )
  rescue ActiveRecord::RecordInvalid => e
    Rails.logger.warn("StreamMonitorWorker: ChatRoomState save failed for #{login} (#{e.message})")
  end

  # poll_predictions / poll_polls / poll_hype_train removed 2026-06-04.
  # Twitch dropped Channel.{activePredictionEvent, currentPoll, hypeTrainExecution}
  # from its public GQL schema; live probe returned "Cannot query field …"
  # errors at ~3/min per active stream from the monitoring_worker container.
  # PredictionsPoll model retained for historical rows; future replacement (if
  # Twitch reintroduces these features) is its own research EPIC.

  # === Scheduling ===

  def increment_cycle
    redis.incr(REDIS_CYCLE_KEY).to_i
  end


  # === Clients ===

  def gql
    @gql ||= Twitch::GqlClient.new
  end

  def helix
    @helix ||= Twitch::HelixClient.new
  end

  def redis
    @redis ||= begin
      r = Redis.new(url: ENV.fetch("REDIS_URL", "redis://localhost:6379/1"))
      r.ping
      r
    rescue Redis::CannotConnectError => e
      Rails.logger.warn("StreamMonitorWorker: Redis unavailable (#{e.message})")
      Redis.new(url: ENV.fetch("REDIS_URL", "redis://localhost:6379/1"))
    end
  end
end
