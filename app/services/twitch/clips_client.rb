# frozen_string_literal: true

# TASK-110 FR-012: Lookup specific Twitch clip metadata by clip_id via Helix /clips.
# Wraps existing Twitch::HelixClient (TASK-021) — reuses app token cache + rate limit handling.
#
# Helix /clips supports both broadcaster_id (existing get_clips) and id array (new get_by_ids).
# TASK-110 use case = lookup specific clip user clicked on (id-based).
#
# IMPORTANT: Call from Sidekiq workers only (HelixClient sleep() в retry handlers blocks thread).

module Twitch
  class ClipsClient
    class Error < StandardError; end
    class ClipNotFoundError < Error; end

    def initialize(helix: Twitch::HelixClient.new)
      @helix = helix
    end

    # Fetch single clip metadata by Twitch clip URL slug (e.g. "AwkwardHelplessSalamanderSwiftRage").
    # Returns Hash with fields: id, broadcaster_id, broadcaster_name, title, game_id, duration,
    # view_count, created_at, video_url, thumbnail_url.
    # Raises ClipNotFoundError if clip private/deleted (Helix returns empty data array).
    def fetch(clip_id:)
      raise ArgumentError, "clip_id is required" if clip_id.blank?

      data = @helix.get_clips_by_ids(ids: [ clip_id ]) # S-5 (CR): public accessor, не send(:get)
      raise ClipNotFoundError, "Clip #{clip_id} not found" if data.blank?

      clip = data.first
      {
        id: clip["id"],
        broadcaster_id: clip["broadcaster_id"],
        broadcaster_name: clip["broadcaster_name"],
        title: clip["title"],
        game_id: clip["game_id"],
        duration_sec: clip["duration"]&.to_f,
        view_count: clip["view_count"]&.to_i,
        started_at: clip["created_at"],
        thumbnail_url: clip["thumbnail_url"]
      }
    end
  end
end
