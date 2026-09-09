# frozen_string_literal: true

module Coordination
  # Folds channel↔channel coordination edges into GROUPS — the "one ring, one pool of accounts"
  # object the channel card and the map render.
  #
  # Pure Ruby over already-aggregated input (a few thousand edges at most), so it is fully
  # unit-testable and carries no ClickHouse dependency. Connected components via union-find with
  # path halving — the same shape the front-end graph uses for its community colouring, except here
  # the edges are coordination edges (shared co-firing accounts), not audience overlap.
  #
  # Why connected components and not a modularity/Louvain split: a coordination edge already
  # survived a hard floor (>= MIN_ACCOUNTS_PER_PAIR accounts co-firing in BOTH channels within 5s).
  # At that floor the graph is not the dense audience-overlap graph that would smear into one blob —
  # verified live 2026-09-09: 24h of real data produced three disjoint components (12, 3 and 3
  # channels), not one. If the floor is ever lowered, revisit this choice rather than the floor.
  class GroupBuilder
    # A pair is not a "group": the event definition itself is ">= 3 distinct channels", so a group
    # that cannot host such an event is not evidence of the thing we are naming.
    MIN_MEMBERS = 3

    # An account counts toward a group only if it co-fired in at least this many of the group's
    # channels. One channel means it is merely present, not linking.
    MIN_CHANNELS_IN_GROUP = 2

    Group = Struct.new(:member_logins, :edges, :accounts, :accounts_shared, :events, :density,
                       keyword_init: true)

    # pairs:    [{ a:, b:, accounts_shared:, events: }]  (Clickhouse::CoordinationQueries#channel_pairs)
    # accounts: [{ username:, events:, max_concurrent:, channels:, last_at: }]  (#accounts)
    def self.call(pairs:, accounts:)
      new(pairs:, accounts:).call
    end

    def initialize(pairs:, accounts:)
      @pairs = pairs
      @accounts = accounts
    end

    def call
      components.filter_map { |logins| build_group(logins) }
                .sort_by { |g| -g.accounts_shared }
    end

    private

    # ── union-find ──────────────────────────────────────────────────────────
    def components
      parent = {}
      find = lambda do |x|
        parent[x] ||= x
        while parent[x] != x
          parent[x] = parent[parent[x]] # path halving
          x = parent[x]
        end
        x
      end

      @pairs.each do |p|
        ra = find.call(p[:a])
        rb = find.call(p[:b])
        parent[ra] = rb unless ra == rb
      end

      parent.keys.group_by { |login| find.call(login) }
            .values
            .select { |logins| logins.size >= MIN_MEMBERS }
            .map(&:sort)
    end

    # ── per-component assembly ──────────────────────────────────────────────
    def build_group(logins)
      member_set = logins.to_set
      edges = @pairs.select { |p| member_set.include?(p[:a]) && member_set.include?(p[:b]) }
      return nil if edges.empty?

      members_accounts = @accounts.filter_map do |acc|
        inside = acc[:channels].count { |c| member_set.include?(c) }
        next if inside < MIN_CHANNELS_IN_GROUP

        acc.merge(channels_in_group: inside)
      end
      return nil if members_accounts.empty?

      Group.new(
        member_logins: logins,
        edges: edges,
        accounts: members_accounts,
        accounts_shared: members_accounts.size,
        events: members_accounts.sum { |a| a[:events] },
        density: density(logins.size, edges.size)
      )
    end

    # Share of the possible member pairs that actually carry a coordination edge. 1.0 = every
    # channel in the group is tied to every other one — the shape a single shared pool produces.
    def density(member_count, edge_count)
      possible = member_count * (member_count - 1) / 2.0
      return 0.0 if possible.zero?

      (edge_count / possible).round(3)
    end
  end
end
