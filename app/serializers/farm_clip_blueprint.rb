# frozen_string_literal: true

# One row of the public «clips of a channel» list (WEB-CONSOLIDATION). Everything here is already
# public on Twitch; the farm's own bookkeeping (game_id, creator ids, first/last_seen_at, the view
# snapshots) stays inside — this is a reader's list of clips, not the capture's audit trail.
class FarmClipBlueprint < Blueprinter::Base
  identifier :clip_id

  fields :url, :title, :thumbnail_url, :view_count, :vod_offset

  # The slug the Twitch embed takes (clips.twitch.tv/embed?clip=<slug>). It IS the Helix clip id —
  # named separately so a reader embedding a clip does not have to know that.
  field :embed_slug do |clip|
    clip.clip_id
  end

  # Seconds, as Twitch reports them; nil when the poller saw no duration on the clip.
  field :duration do |clip|
    clip.duration&.to_f
  end

  # When the clip was made on Twitch — never the timestamp of our own row.
  field :created_at do |clip|
    clip.twitch_created_at&.iso8601
  end
end
