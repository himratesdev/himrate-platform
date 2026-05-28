# frozen_string_literal: true

module PersonalAnalytics
  # TASK-113 BE-3 (FR-008 / M8 tenure → вход M9): ingest client-captured sub-tenure snapshots
  # (IRC badge-info — extension читает СВОИ sub-бейджи) → channel_tenure. Идемпотентно BY REPLACE:
  # upsert_all unique (user_id, twitch_channel_id) (latest badge-info wins; update_only без created_at).
  # Питает Supporter::StatusBuilder (composite tenure_mo·2) + SupporterService (tenure_months/sub_tier).
  # Это writer для M8 (CR SF-1 — раньше channel_tenure читался, но никто не писал).
  class TenureIngestWorker
    include Sidekiq::Job
    sidekiq_options queue: :default, retry: 3

    SUB_TIERS = [ 1, 2, 3 ].freeze

    def perform(user_id, snapshots)
      snapshots = Array(snapshots).map { |snap| normalize(snap) }
      return if snapshots.empty?

      channels = ChannelEnrichment.resolve(snapshots.map { |snap| snap[:channel_id] })
      rows = snapshots.filter_map { |snap| build_row(user_id, snap, channels) }
      return if rows.empty?

      ChannelTenure.upsert_all(
        rows, unique_by: %i[user_id twitch_channel_id],
              update_only: %i[channel_id twitch_login sub_tier months streak anniversary_at observed_at]
      )
    end

    private

    def build_row(user_id, snapshot, channels)
      twitch_channel_id = snapshot[:channel_id].to_s
      observed_at = parse_time(snapshot[:observed_at])
      return drop(user_id, snapshot) unless Ingest.valid_channel_id?(twitch_channel_id) && observed_at

      uuid, login = channels[twitch_channel_id]
      now = Time.current
      { user_id: user_id, twitch_channel_id: twitch_channel_id, channel_id: uuid,
        twitch_login: Ingest.truncate_login(login || snapshot[:login]), sub_tier: clamp_tier(snapshot[:sub_tier]),
        months: Ingest.clamp_int(snapshot[:months]), streak: Ingest.clamp_int(snapshot[:streak]),
        anniversary_at: parse_date(snapshot[:anniversary_at]), observed_at: observed_at,
        created_at: now, updated_at: now }
    end

    def clamp_tier(value)
      tier = value.to_i
      SUB_TIERS.include?(tier) ? tier : nil
    end

    def normalize(snapshot)
      snapshot.is_a?(Hash) ? snapshot.deep_symbolize_keys : {}
    end

    def parse_date(value)
      return value if value.is_a?(Date)
      return nil if value.blank?

      Date.iso8601(value.to_s)
    rescue ArgumentError
      nil
    end

    def parse_time(value)
      return value if value.is_a?(Time) || value.is_a?(ActiveSupport::TimeWithZone)
      return nil if value.blank?

      Time.iso8601(value.to_s)
    rescue ArgumentError
      nil
    end

    def drop(user_id, snapshot)
      Rails.logger.warn("TenureIngestWorker: dropped user=#{user_id} channel=#{snapshot[:channel_id].inspect}")
      nil
    end
  end
end
