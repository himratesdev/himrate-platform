# frozen_string_literal: true

module PersonalAnalytics
  # TASK-113 BE-3: общий resolve Twitch channel id → enrichment. Зритель смотрит/донатит на
  # ПРОИЗВОЛЬНЫХ каналах → channels-запись есть только для tracked; untracked → не в hash (nil
  # enrichment у вызывающего). Один batch-запрос, no N+1. Используется ingest-worker'ами.
  module ChannelEnrichment
    # @return [Hash] { twitch_id(String) => [channels.id(uuid), login] } только для tracked каналов.
    def self.resolve(twitch_ids)
      ids = Array(twitch_ids).map { |id| id.to_s.presence }.compact.uniq
      return {} if ids.empty?

      Channel.where(twitch_id: ids).pluck(:twitch_id, :id, :login)
             .to_h { |twitch_id, id, login| [ twitch_id, [ id, login ] ] }
    end
  end
end
