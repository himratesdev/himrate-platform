# frozen_string_literal: true

module Coordination
  # Rebuilds the persisted ring snapshot: ClickHouse → groups → Postgres.
  #
  # Pipeline: co-firing accounts over the window → channel↔channel edges → connected components
  # (GroupBuilder) → corroboration against the engine's own named-bot evidence → posting rhythm for
  # the accounts we keep → one transactional rewrite of the four tables.
  #
  # Snapshot-recompute, like the sibling cross-channel tables. Group IDENTITY is carried across
  # sweeps by membership overlap, not by row survival: a link to a group has to keep working when
  # the ring gains or loses a channel, and `first_seen_at` is only meaningful if it survives too.
  class Snapshot
    WINDOW_DAYS = 7        # channels do not stream daily — 24h hides half the ring (verified live)
    ACCOUNTS_KEPT = 200    # per group: the strongest evidence, not the whole pool
    IDENTITY_OVERLAP = 0.5 # Jaccard over member logins above which a group is "the same ring"

    # Corroboration floor. Both conditions, deliberately: a handful of flagged accounts inside ONE
    # channel is that channel's own verdict, not evidence about the ring.
    MIN_CORROBORATED_ACCOUNTS = 5
    MIN_CORROBORATED_CHANNELS = 2

    NAMED_BOT_LOOKBACK = 30.days

    def self.call(window_days: WINDOW_DAYS)
      new(window_days:).call
    end

    def initialize(window_days: WINDOW_DAYS)
      @window_days = window_days
      @computed_at = Time.current
    end

    # Returns { groups:, members:, accounts:, corroborated: } for the worker log.
    def call
      accounts = Clickhouse::CoordinationQueries.accounts(days: @window_days)
      pairs = Clickhouse::CoordinationQueries.channel_pairs(days: @window_days)
      groups = GroupBuilder.call(pairs:, accounts:)

      persist(groups)
    end

    private

    def persist(groups)
      previous = CoordinationGroup.includes(:members).to_a
      kept_ids = []

      ActiveRecord::Base.transaction do
        groups.each do |group|
          record = upsert_group(group, previous)
          kept_ids << record.id
          write_members(record, group)
          write_edges(record, group)
          write_accounts(record, group)
        end

        stale = previous.reject { |g| kept_ids.include?(g.id) }
        CoordinationGroup.where(id: stale.map(&:id)).destroy_all if stale.any?
      end

      {
        groups: kept_ids.size,
        members: CoordinationGroup.where(id: kept_ids).sum(:member_count),
        accounts: CoordinationGroup.where(id: kept_ids).sum(:accounts_shared),
        corroborated: CoordinationGroup.where(id: kept_ids, corroborated: true).count
      }
    end

    # ── group row ───────────────────────────────────────────────────────────
    def upsert_group(group, previous)
      corroboration = corroborate(group)
      match = best_match(group.member_logins, previous)

      record = match || CoordinationGroup.new(first_seen_at: @computed_at)
      record.assign_attributes(
        member_count: group.member_logins.size,
        accounts_shared: group.accounts_shared,
        events: group.events,
        density: group.density,
        window_days: @window_days,
        computed_at: @computed_at,
        **corroboration
      )
      record.save!
      record
    end

    # The same ring is the previous group sharing most members. Below IDENTITY_OVERLAP it is a
    # different ring that happens to touch a shared channel, and it gets a fresh id + first_seen_at.
    def best_match(logins, previous)
      set = logins.to_set
      scored = previous.map do |g|
        other = g.members.map(&:channel_login).to_set
        union = (set | other).size
        [ g, union.zero? ? 0.0 : (set & other).size.to_f / union ]
      end
      best, score = scored.max_by { |(_, s)| s }
      score.to_f >= IDENTITY_OVERLAP ? best : nil
    end

    # ── corroboration ───────────────────────────────────────────────────────
    # Intersect the ring's pool with named_bot_evidences — the only store that already carries a
    # hard, dispute-backed per-account verdict from the TI engine. This is what licenses the
    # accusatory headline; without it the card states the observation and its numbers only.
    def corroborate(group)
      channel_ids = Channel.where(login: group.member_logins).pluck(:id)
      usernames = group.accounts.map { |a| a[:username] }
      return blank_corroboration if channel_ids.empty? || usernames.empty?

      hits = NamedBotEvidence.where(channel_id: channel_ids, username: usernames)
                             .where(calculated_at: NAMED_BOT_LOOKBACK.ago..)
                             .distinct.pluck(:username, :channel_id)

      accounts = hits.map(&:first).uniq.size
      channels = hits.map(&:last).uniq.size
      {
        corroborated_accounts: accounts,
        corroborated_channels: channels,
        corroborated: accounts >= MIN_CORROBORATED_ACCOUNTS && channels >= MIN_CORROBORATED_CHANNELS
      }
    end

    def blank_corroboration
      { corroborated_accounts: 0, corroborated_channels: 0, corroborated: false }
    end

    # ── children ────────────────────────────────────────────────────────────
    def write_members(record, group)
      record.members.delete_all
      channels = Channel.where(login: group.member_logins).pluck(:login, :id).to_h
      ties = Hash.new(0)
      events = Hash.new(0)
      group.edges.each do |e|
        ties[e[:a]] += e[:accounts_shared]
        ties[e[:b]] += e[:accounts_shared]
        events[e[:a]] += e[:events]
        events[e[:b]] += e[:events]
      end
      per_channel_accounts = group.accounts.each_with_object(Hash.new(0)) do |acc, memo|
        acc[:channels].each { |c| memo[c] += 1 if group.member_logins.include?(c) }
      end

      rows = group.member_logins.map do |login|
        {
          coordination_group_id: record.id,
          channel_id: channels[login],
          channel_login: login,
          ties: ties[login],
          accounts: per_channel_accounts[login],
          events: events[login],
          created_at: @computed_at, updated_at: @computed_at
        }
      end
      CoordinationGroupMember.insert_all!(rows) if rows.any?
    end

    def write_edges(record, group)
      record.edges.delete_all
      rows = group.edges.map do |e|
        {
          coordination_group_id: record.id,
          a_login: e[:a], b_login: e[:b],
          accounts_shared: e[:accounts_shared], events: e[:events],
          created_at: @computed_at, updated_at: @computed_at
        }
      end
      CoordinationEdge.insert_all!(rows) if rows.any?
    end

    def write_accounts(record, group)
      record.accounts.delete_all
      kept = group.accounts.sort_by { |a| [ -a[:events], -a[:channels_in_group] ] }.first(ACCOUNTS_KEPT)
      named = named_bot_usernames(group, kept)
      rhythm = rhythm_for(group, kept)

      rows = kept.map do |acc|
        r = rhythm[acc[:username]] || {}
        {
          coordination_group_id: record.id,
          username: acc[:username],
          channels_in_group: acc[:channels_in_group],
          events: acc[:events],
          max_concurrent: acc[:max_concurrent],
          median_interval_sec: r[:median_interval_sec],
          interval_cv: r[:interval_cv],
          named_bot: named.include?(acc[:username]),
          last_at: acc[:last_at],
          created_at: @computed_at, updated_at: @computed_at
        }
      end
      CoordinationAccount.insert_all!(rows) if rows.any?
    end

    def named_bot_usernames(group, kept)
      channel_ids = Channel.where(login: group.member_logins).pluck(:id)
      return Set.new if channel_ids.empty?

      NamedBotEvidence.where(channel_id: channel_ids, username: kept.map { |a| a[:username] })
                      .where(calculated_at: NAMED_BOT_LOOKBACK.ago..)
                      .distinct.pluck(:username).to_set
    end

    # Rhythm is a bounded extra scan (this ring's channels, these accounts, 24h). A ClickHouse
    # failure here must not lose the group — the rhythm columns are evidence colour, not the finding.
    def rhythm_for(group, kept)
      Clickhouse::CoordinationQueries.rhythm(group.member_logins, kept.map { |a| a[:username] })
    rescue Clickhouse::Error => e
      Rails.logger.warn("Coordination::Snapshot rhythm skipped: #{e.class}: #{e.message}")
      {}
    end
  end
end
