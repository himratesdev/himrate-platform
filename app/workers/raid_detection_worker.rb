# frozen_string_literal: true

# TASK-251.B: classify raids captured as IRC USERNOTICE (msg_type="raid") into RaidAttribution
# records so the Raid Attribution signal (#9) sees real bot-raids. Until now the table stayed empty:
# RaidWorker was an EventSub stub and EventSub channel.raid never delivered on staging, so #9 always
# returned 0.0 ("clean") regardless of actual raids.
#
# Source (verified live on staging): a raid USERNOTICE arrives in the *raided* channel with
#   raw_tags["msg-param-login"]       = raider login (the source channel)
#   raw_tags["user-id"]               = raider Twitch id
#   raw_tags["msg-param-viewerCount"] = raiders brought
#   chat_messages.stream_id           = the raided stream (linked by ChatMessageWorker, 1111/1116)
#
# Classification (server-side-reliable subset of BFT 33 §3.2's 5-signal stack): the precise raider
# list is only available from the browser-context GQL community/chatters feed, which is
# integrity-blocked server-side (the same wall as auth_ratio #1). So we can only isolate the raider
# cohort when the raid is LARGE relative to the target's baseline audience — a small raid on a big
# channel can't be told apart from organic chat churn (a 25-viewer raid on a 27k-CCV channel
# produced 366 "newcomers"), and it doesn't materially affect that channel's TI anyway. Therefore:
#   - every raid is RECORDED (the event itself is reliable),
#   - is_bot_raid / bot_score are computed ONLY for "significant" raids (raid ≥ baseline × RATIO),
#     where the post-raid newcomer cohort ≈ raiders and the signal stack carries information,
#   - non-significant raids are recorded with is_bot_raid=false / bot_score=nil + a reason; precise
#     per-raider refinement of all raids + the chain graph come later via the gql_data ingest
#     (TASK-L1 / the auth_ratio path).
#
# Signals used (4, each scored only when computable — the denominator is "available" signals):
#   write_rate    — newcomers who wrote / raiders brought   (bots don't chat;     BFT bot<5 / org>30)
#   account_age   — % of profiled newcomers with <30d accounts (ChatterProfile;   BFT bot>70 / org<15)
#   cross_channel — % of newcomers seen in ≥10 channels/24h  (bots farm channels;  BFT bot>80 / org<1)
#   ccv_decay     — raid CCV spike that decays >50% in POST_WINDOW (bots vanish;   BFT t½<5m / org 15-30m)
# BFT's 5th signal (raiders subscribed to target <1%) is intentionally dropped: server-side it sits
# near 0 for organic raids too (raiders are rarely target subs), so it would always fire and inflate
# the count — the #11 "always-fire flag" mistake. Precise sub-status of the full cohort = gql_data.
#
# Runs on :monitoring (NOT the :signals hot path) and reads only the DB (no external API), so it
# never competes with signal compute. Idempotent via raid_attributions.twitch_msg_id.
#
# PR-251.14 PR 1e-A follow-up (2026-05-31): post PR #231 the ChatMessageWorker stopped
# dual-writing chat to Postgres, so this worker now reads chat_messages exclusively from
# ClickHouse via Clickhouse::ChatQueries. Three call sites migrated:
#   - unprocessed_raids  → raid_messages_pending (CH source) + Ruby NOT-EXISTS dedup against PG raid_attributions
#   - privmsg_logins     → ChatQueries.privmsg_logins (signature now takes Stream, not stream_id)
#   - cross_channel_signal → ChatQueries.chatter_cross_channel_counts (shared with BotScoringWorker)
# Without this migration signal #9 went silent after PR #231 merge (verified live: 0 RaidAttribution
# rows written between 05:49Z and 11:00Z despite captured organic raids).
class RaidDetectionWorker
  include Sidekiq::Job
  sidekiq_options queue: :monitoring, retry: 1

  MATURITY    = 8.minutes  # wait for the post-raid cohort to chat + CCV to settle before classifying
  LOOKBACK    = 3.hours    # bound the scan window (also catches a missed run)
  MAX_PER_RUN = 200        # raids are sparse (~20/h); cron clears any backlog
  PRE_WINDOW  = 15.minutes # baseline chatter window before the raid
  POST_WINDOW = 5.minutes  # post-raid cohort window (BFT §3.1: profile 5 min after the raid)
  CROSS_CHANNEL_WINDOW = 24.hours
  COHORT_SAMPLE_CAP = 500  # bound the per-raid cohort lookups for very large (significant) raids

  # Significance: only classify when the raid is large vs the target baseline, so the post-raid
  # newcomers are dominated by raiders (cohort isolable). baseline = max(pre-raid chatters, CCV)
  # is conservative — a raid that's noise relative to a big lurking audience stays unclassified.
  SIGNIFICANCE_RATIO = 0.5 # raid_viewers ≥ baseline × this
  SIGNIFICANCE_FLOOR = 10  # and at least this many raiders (tiny raids = noise)

  # Oversample factor for CH fetch (CR-234 Should-1). PG path applied NOT EXISTS BEFORE LIMIT, so
  # the worker always returned ≤MAX_PER_RUN *new* raids. CH ↔ PG NOT EXISTS isn't possible so the
  # filter runs in Ruby AFTER LIMIT — meaning if 200 in-window candidates are all already-processed,
  # no new raids progress this run. Raids are sparse (~20/h × 3h LOOKBACK ≈ 60 ≪ 200) so the risk
  # is currently nil, but oversampling at 3× MAX_PER_RUN gives 3-4× volume headroom for free.
  CH_CANDIDATE_LIMIT = MAX_PER_RUN * 3

  # Signal thresholds (BFT 33 §3.2; lean toward specificity — never mislabel an organic raid).
  ACCOUNT_AGE_DAYS      = 30
  ACCOUNT_AGE_TRIGGER   = 0.50 # bot if >50% of profiled newcomers have <30d accounts
  MIN_PROFILED          = 3    # need at least this many profiled newcomers to score account age
  CROSS_CHANNEL_MIN     = 10   # "present in ≥10 channels/day"
  CROSS_CHANNEL_TRIGGER = 0.40 # bot if >40% of newcomers are in ≥10 channels
  WRITE_RATE_TRIGGER    = 0.10 # bot if <10% of raiders ever wrote
  CCV_RETENTION_TRIGGER = 0.50 # bot if the raid CCV spike retains <50% by POST_WINDOW (decayed away)
  CCV_SPIKE_MIN_FRACTION = 0.30 # the raid must show as ≥30% of viewers in CCV to measure decay
  BOT_RAID_MIN_SIGNALS  = 3    # ≥3 of the available signals → bot-raid (BFT ≥3/5)

  def perform
    return unless Flipper.enabled?(:stream_monitor) && Flipper.enabled?(:raid_detection)

    raids = unprocessed_raids
    return if raids.empty?

    recorded = raids.count { |raid| process_raid(raid) }
    Rails.logger.info("RaidDetectionWorker: wrote #{recorded}/#{raids.size} raid attributions")
  end

  private

  # Matured raid USERNOTICEs with a linked stream that have not been classified yet. Post PR #231
  # (PG chat_messages dual-write dropped → CH is sole writer for chat) the source is ClickHouse;
  # the NOT EXISTS dedup against PG raid_attributions can't be done in CH (cross-DB), so we fetch
  # up to MAX_PER_RUN candidates from CH then strip already-recorded msg_ids in Ruby. Net result
  # is the same row shape callers expect — Hashes with stream_id / timestamp / username /
  # twitch_msg_id / raw_tags keys (vs the prior ChatMessage AR records).
  def unprocessed_raids
    candidates = Clickhouse::ChatQueries.raid_messages_pending(
      since:  LOOKBACK.ago,
      until_: MATURITY.ago,
      limit:  CH_CANDIDATE_LIMIT
    )
    return [] if candidates.empty?

    already_recorded = RaidAttribution
      .where(twitch_msg_id: candidates.map { |c| c[:twitch_msg_id] })
      .pluck(:twitch_msg_id)
      .to_set
    candidates
      .reject { |c| already_recorded.include?(c[:twitch_msg_id]) }
      .first(MAX_PER_RUN)
  end

  def process_raid(msg)
    tags = msg[:raw_tags] || {}
    viewers = tags["msg-param-viewerCount"].to_i
    stream = Stream.find_by(id: msg[:stream_id])
    return false if viewers <= 0 || stream.nil?

    result = classify(stream: stream, raid_time: msg[:timestamp], viewers: viewers)
    RaidAttribution.create!(
      stream_id: stream.id,
      source_channel_id: Channel.find_by(twitch_id: tags["user-id"])&.id,
      timestamp: msg[:timestamp],
      raid_viewers_count: viewers,
      is_bot_raid: result[:is_bot_raid],
      bot_score: result[:bot_score],
      signal_scores: result[:breakdown],
      twitch_msg_id: msg[:twitch_msg_id]
    )
    true
  rescue ActiveRecord::RecordNotUnique
    false # raced with a concurrent run; already recorded
  rescue StandardError => e
    # Isolate a single bad raid (malformed tags / transient query error) so it can't stall the rest
    # of the ordered batch until it ages past LOOKBACK — same per-unit rescue philosophy as
    # ContextBuilder. RecordInvalid is a StandardError, so create! validation failures land here too.
    Rails.logger.warn("RaidDetectionWorker: #{msg[:twitch_msg_id]} failed (#{e.class}: #{e.message.to_s.truncate(120)})")
    false
  end

  def classify(stream:, raid_time:, viewers:)
    baseline = baseline_audience(stream, raid_time)
    return insignificant(viewers, baseline) unless significant?(viewers, baseline)

    newcomers = post_raid_newcomers(stream, raid_time)
    signals = {
      write_rate: write_rate_signal(newcomers, viewers),
      account_age: account_age_signal(newcomers),
      cross_channel: cross_channel_signal(newcomers),
      ccv_decay: ccv_decay_signal(stream, raid_time, viewers)
    }
    verdict(signals, baseline: baseline, viewers: viewers, cohort_size: newcomers.size)
  end

  def verdict(signals, baseline:, viewers:, cohort_size:)
    available = signals.values.count { |s| !s[:value].nil? }
    triggered = signals.values.count { |s| s[:triggered] }
    {
      is_bot_raid: available >= BOT_RAID_MIN_SIGNALS && triggered >= BOT_RAID_MIN_SIGNALS,
      bot_score: available.zero? ? nil : (triggered.to_f / available).round(4),
      breakdown: { significant: true, baseline: baseline, viewers: viewers,
                   cohort_size: cohort_size, available: available, triggered: triggered, signals: signals }
    }
  end

  def insignificant(viewers, baseline)
    { is_bot_raid: false, bot_score: nil,
      breakdown: { significant: false, reason: "insufficient_isolation", viewers: viewers, baseline: baseline } }
  end

  # --- significance ---------------------------------------------------------

  def significant?(viewers, baseline)
    viewers >= SIGNIFICANCE_FLOOR && viewers >= baseline * SIGNIFICANCE_RATIO
  end

  def baseline_audience(stream, raid_time)
    chatters = privmsg_logins(stream, raid_time - PRE_WINDOW, raid_time).size
    ccv = latest_ccv_before(stream, raid_time) || 0
    [ chatters, ccv ].max
  end

  # --- cohort ---------------------------------------------------------------

  # New chatters in the post-raid window who were not chatting in the pre-raid window ≈ raiders
  # (only reliable when the raid is significant; gated above). Capped for very large raids.
  def post_raid_newcomers(stream, raid_time)
    pre = privmsg_logins(stream, raid_time - PRE_WINDOW, raid_time)
    post = privmsg_logins(stream, raid_time, raid_time + POST_WINDOW)
    (post - pre).first(COHORT_SAMPLE_CAP)
  end

  # PR-251.14-followup: post PR #231 the chat writer no longer dual-writes to PG, so the
  # distinct-usernames-in-window scan reads ClickHouse (the sole source of truth for chat).
  # Same semantics as the prior PG path: distinct usernames, msg_type='privmsg', stream-scoped,
  # half-open window [from, to).
  def privmsg_logins(stream, from, to)
    Clickhouse::ChatQueries.privmsg_logins(stream, from: from, to: to)
  end

  # --- signals (each returns { value:, triggered: }; value=nil → not computable, excluded) -------

  def write_rate_signal(newcomers, viewers)
    return blank_signal if viewers <= 0

    rate = [ newcomers.size.to_f / viewers, 1.0 ].min
    { value: rate.round(4), triggered: rate < WRITE_RATE_TRIGGER }
  end

  def account_age_signal(newcomers)
    return blank_signal if newcomers.empty?

    ages = ChatterProfile.where(login: newcomers).where.not(twitch_created_at: nil).pluck(:twitch_created_at)
    return blank_signal if ages.size < MIN_PROFILED

    young = ages.count { |created_at| created_at > ACCOUNT_AGE_DAYS.days.ago }
    ratio = young.to_f / ages.size
    { value: ratio.round(4), triggered: ratio > ACCOUNT_AGE_TRIGGER, profiled: ages.size }
  end

  def cross_channel_signal(newcomers)
    return blank_signal if newcomers.empty?

    # PR-251.14-followup: same CH cross-channel-distinct-channel-count helper that
    # BotScoringWorker uses (post PR #231 cutover). Window aligned to the prior PG `> ?` shape
    # by passing `CROSS_CHANNEL_WINDOW.ago` directly (chatter_cross_channel_counts uses `>` on
    # the cutoff so the open boundary matches).
    #
    # CR-258 N-iter2-1 (BUG-SCW-CROSS-CHANNEL): intentionally NOT routed through the digest
    # path that ContextBuilder + BotScoringWorker use. Three reasons it's safe to keep on the
    # legacy CH scan here:
    #   1. Denominator is `newcomers.size` (below), not `counts.size` — the M1 denominator-
    #      collapse risk that motivated `fetch_with_baseline` doesn't apply.
    #   2. `CROSS_CHANNEL_MIN = 10` is well above the digest's `HAVING c > 1` filter — the
    #      single-channel chatters omitted from the digest would not have flipped `in_many`
    #      either way.
    #   3. Worker runs */5 min on `:monitoring` (sparse raid traffic, ~20/hour) — not the
    #      :signal_compute hot path the digest was built to relieve.
    # If the CH scan latency becomes a problem here too (currently it isn't — `newcomers` set
    # is small per-raid), revisit then; today a third call site reading from a still-OK CH
    # primitive is the right trade-off.
    counts = Clickhouse::ChatQueries.chatter_cross_channel_counts(newcomers, CROSS_CHANNEL_WINDOW.ago)
    return blank_signal if counts.empty?

    in_many = counts.count { |_, n| n >= CROSS_CHANNEL_MIN }
    ratio = in_many.to_f / newcomers.size
    { value: ratio.round(4), triggered: ratio > CROSS_CHANNEL_TRIGGER }
  end

  # Raid injects viewers; bots leave within minutes (short half-life) while organic raiders linger.
  # Measurable only when the raid actually shows up in CCV (≥30% of viewers) given coarse snapshots.
  def ccv_decay_signal(stream, raid_time, viewers)
    before = latest_ccv_before(stream, raid_time)
    peak = stream.ccv_snapshots.where(timestamp: raid_time..(raid_time + 3.minutes)).maximum(:ccv_count)
    late = stream.ccv_snapshots.where("timestamp >= ?", raid_time + POST_WINDOW).order(:timestamp).limit(1).pick(:ccv_count)
    return blank_signal unless before && peak && late

    spike = peak - before
    return blank_signal if spike < viewers * CCV_SPIKE_MIN_FRACTION

    retained = (late - before).to_f / spike
    { value: retained.round(4), triggered: retained < CCV_RETENTION_TRIGGER }
  end

  def latest_ccv_before(stream, raid_time)
    stream.ccv_snapshots.where("timestamp < ?", raid_time).order(timestamp: :desc).limit(1).pick(:ccv_count)
  end

  def blank_signal
    { value: nil, triggered: false }
  end
end
