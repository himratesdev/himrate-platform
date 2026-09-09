# frozen_string_literal: true

module Coordination
  # Read side of the coordination layer: turns the persisted snapshot into the payload the channel
  # card and the map render.
  #
  # Two shapes, one object:
  #   * `for_channel(login)` — the banner: is this channel in a ring, how big, how strong, who else.
  #   * `for_group(id)`      — the "Разобрать" panel: the same plus edges (matrix) and the account
  #                            evidence table.
  #
  # WORDING CONTRACT. `headline` is the ONLY thing that decides how hard the card may speak, and it
  # is derived here, never in the front end:
  #   * "verdict"     — corroborated: the ring's account pool intersects the engine's own hard
  #                     named-bot evidence across at least two of its channels. PO decision
  #                     2026-09-09 licenses the accusatory headline in this case only.
  #   * "observation" — everything else: state the numbers, name nothing. The reader concludes.
  # Both carry the same evidence, so an observation is not a weaker product — just a truthful one.
  class Presenter
    # Evidence rows handed to the panel in one go. The table is sortable client-side; beyond this
    # the payload stops being a page and starts being a dataset.
    ACCOUNTS_LIMIT = 100

    class << self
      def for_channel(login)
        login = login.to_s.downcase
        group = CoordinationGroup.for_channel_login(login).first
        return { login: login, in_group: false } unless group

        { login: login, in_group: true, group: summary(group, focus: login) }
      end

      def for_group(id, focus: nil)
        group = CoordinationGroup.find_by(id: id)
        return nil unless group

        summary(group, focus: focus&.downcase).merge(
          edges: edges(group),
          accounts: accounts(group)
        )
      end

      private

      def summary(group, focus: nil)
        {
          id: group.id,
          headline: group.corroborated ? "verdict" : "observation",
          corroborated: group.corroborated,
          corroborated_accounts: group.corroborated_accounts,
          corroborated_channels: group.corroborated_channels,
          member_count: group.member_count,
          accounts_shared: group.accounts_shared,
          events: group.events,
          density: group.density&.to_f,
          window_days: group.window_days,
          first_seen_at: group.first_seen_at,
          computed_at: group.computed_at,
          members: members(group, focus),
          # Provenance is part of the finding, not a footnote: this is an accusation, and it is
          # built on the monitored chat archive only — the farm capture never enters it.
          basis: {
            source: "monitored_chat",
            window_seconds: Clickhouse::CoordinationQueries::WINDOW_SECONDS,
            min_channels: Clickhouse::CoordinationQueries::MIN_CHANNELS,
            max_concurrent: Clickhouse::CoordinationQueries::DEDICATED_MAX_CONCURRENT
          }
        }
      end

      def members(group, focus)
        rows = group.members.order(ties: :desc).to_a
        channels = Channel.where(login: rows.map(&:channel_login)).index_by(&:login)
        bands = latest_bands(channels.values.map(&:id))

        rows.map do |m|
          channel = channels[m.channel_login]
          {
            login: m.channel_login,
            name: channel&.display_name.presence || m.channel_login,
            avatar_url: channel&.profile_image_url,
            tracked: channel.present?,
            band: (channel && bands[channel.id]) || "grey",
            ties: m.ties,
            accounts: m.accounts,
            events: m.events,
            is_focus: focus.present? && m.channel_login == focus
          }
        end
      end

      def edges(group)
        group.edges.order(accounts_shared: :desc).map do |e|
          { a: e.a_login, b: e.b_login, accounts_shared: e.accounts_shared, events: e.events }
        end
      end

      def accounts(group)
        group.accounts.strongest.limit(ACCOUNTS_LIMIT).map do |a|
          {
            username: a.username,
            channels_in_group: a.channels_in_group,
            events: a.events,
            max_concurrent: a.max_concurrent,
            median_interval_sec: a.median_interval_sec&.to_f,
            interval_cv: a.interval_cv&.to_f,
            named_bot: a.named_bot,
            last_at: a.last_at
          }
        end
      end

      def latest_bands(ids)
        return {} if ids.empty?

        TrustIndexHistory
          .where(channel_id: ids, engine_version: "v2")
          .select("DISTINCT ON (channel_id) channel_id, band_color")
          .order(:channel_id, calculated_at: :desc)
          .to_h { |t| [t.channel_id, t[:band_color]] }
      end
    end
  end
end
