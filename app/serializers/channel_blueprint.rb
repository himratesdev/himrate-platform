# frozen_string_literal: true

# TASK-031 FR-006/008: Channel serializer with tier-scoped views.
# headline (Guest) → drill_down (Free live/18h) → full (Premium tracked).
# Uses Ruby sort (max_by) on preloaded associations to avoid N+1 queries.

class ChannelBlueprint < Blueprinter::Base
  identifier :id

  # PR3b (T1-074): latest row of the ACTIVE engine, Ruby-side over the preloaded association
  # (preserves the no-N+1 property of list endpoints — do NOT switch to a per-channel DB query).
  # TrustIndexBlueprint is per-row engine-aware, so the pick only decides WHICH engine's latest row
  # renders.
  def self.latest_tih_for(channel)
    engine = ti_v2_engine? ? "v2" : "v1"
    if channel.trust_index_histories.loaded?
      channel.trust_index_histories.select { |t| t.engine_version == engine }.max_by(&:calculated_at)
    else
      channel.trust_index_histories.where(engine_version: engine).order(calculated_at: :desc).first
    end
  end

  def self.ti_v2_engine?
    Flipper.enabled?(:ti_v2_engine)
  rescue StandardError
    false
  end

  # === Headline view (Guest — always available) ===
  view :headline do
    fields :login, :display_name, :profile_image_url, :twitch_id, :is_monitored

    # Accepts preloaded watched_channel_ids set to avoid N+1 in list endpoints.
    # Single-channel endpoints (show) pass no set — single DB query is acceptable.
    field :is_watched_by_user do |channel, options|
      user = options[:current_user]
      next false unless user

      preloaded = options[:watched_channel_ids]
      if preloaded
        preloaded.include?(channel.id)
      else
        TrackedChannel.where(user: user, channel: channel, tracking_enabled: true).exists?
      end
    end

    association :latest_trust_index, blueprint: TrustIndexBlueprint, view: :headline,
      name: :trust_index do |channel, _options|
      ChannelBlueprint.latest_tih_for(channel)
    end

    field :is_live do |channel, _options|
      channel.streams.loaded? ? channel.streams.any? { |s| s.ended_at.nil? } : channel.streams.where(ended_at: nil).exists?
    end
  end

  # === Drill-down view (Free — live or within 18h window) ===
  view :drill_down do
    include_view :headline

    association :latest_trust_index, blueprint: TrustIndexBlueprint, view: :drill_down,
      name: :trust_index do |channel, _options|
      ChannelBlueprint.latest_tih_for(channel)
    end

    association :current_stream, blueprint: StreamBlueprint, view: :basic do |channel, _options|
      if channel.streams.loaded?
        channel.streams.select { |s| s.ended_at.nil? }.max_by(&:started_at)
      else
        channel.streams.where(ended_at: nil).order(started_at: :desc).first
      end
    end
  end

  # === Full view (Premium tracked — full history) ===
  view :full do
    include_view :drill_down

    association :latest_trust_index, blueprint: TrustIndexBlueprint, view: :full,
      name: :trust_index do |channel, _options|
      ChannelBlueprint.latest_tih_for(channel)
    end

    association :recent_streams, blueprint: StreamBlueprint, view: :basic do |channel, _options|
      # CR-iter1 MF-1 (PR-A1): StreamBlueprint :basic now derives peak_ccv / avg_ccv /
      # duration_ms via Stream#current_* which reads `post_stream_report`. Preload PSR so
      # rendering 5 streams ≠ 5 extra SELECTs. (Loaded? branch presumes caller eager-loaded
      # `channel.streams: :post_stream_report` already; otherwise hits same N+1 — Bullet
      # raises in development.)
      if channel.streams.loaded?
        channel.streams.select(&:ended_at).sort_by(&:started_at).reverse.first(5)
      else
        channel.streams
               .where.not(ended_at: nil)
               .includes(:post_stream_report)
               .order(started_at: :desc)
               .limit(5)
      end
    end

    field :tracked_since do |channel, options|
      user = options[:current_user]
      next nil unless user

      TrackedChannel.where(user: user, channel: channel).pick(:added_at)
    end
  end
end
