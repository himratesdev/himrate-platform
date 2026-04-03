# frozen_string_literal: true

# TASK-031 FR-006/008: Channel serializer with tier-scoped views.
# headline (Guest) → drill_down (Free live/18h) → full (Premium tracked).
# Uses Ruby sort (max_by) on preloaded associations to avoid N+1 queries.

class ChannelBlueprint < Blueprinter::Base
  identifier :id

  # === Headline view (Guest — always available) ===
  view :headline do
    fields :login, :display_name, :profile_image_url, :twitch_id, :is_monitored

    field :is_watched_by_user do |channel, options|
      user = options[:current_user]
      next false unless user

      TrackedChannel.where(user: user, channel: channel, tracking_enabled: true).exists?
    end

    association :latest_trust_index, blueprint: TrustIndexBlueprint, view: :headline,
      name: :trust_index do |channel, _options|
      channel.trust_index_histories.loaded? ? channel.trust_index_histories.max_by(&:calculated_at) : channel.trust_index_histories.order(calculated_at: :desc).first
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
      channel.trust_index_histories.loaded? ? channel.trust_index_histories.max_by(&:calculated_at) : channel.trust_index_histories.order(calculated_at: :desc).first
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
      channel.trust_index_histories.loaded? ? channel.trust_index_histories.max_by(&:calculated_at) : channel.trust_index_histories.order(calculated_at: :desc).first
    end

    association :recent_streams, blueprint: StreamBlueprint, view: :basic do |channel, _options|
      if channel.streams.loaded?
        channel.streams.select(&:ended_at).sort_by(&:started_at).reverse.first(5)
      else
        channel.streams.where.not(ended_at: nil).order(started_at: :desc).limit(5)
      end
    end

    field :tracked_since do |channel, options|
      user = options[:current_user]
      next nil unless user

      TrackedChannel.where(user: user, channel: channel).pick(:added_at)
    end
  end
end
