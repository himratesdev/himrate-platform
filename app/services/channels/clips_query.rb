# frozen_string_literal: true

module Channels
  # Public «clips of a channel» (WEB-CONSOLIDATION): the broadcaster's clips out of the farm pool
  # (FarmClip rows, upserted by Farm::ClipsPollerWorker for every enabled farmed category, joined to
  # the channel by Twitch id). Ranked so a clip that is climbing can beat one that is merely old.
  #
  #   SCORE = view_count + PROJECTION_HOURS × velocity
  #
  # — "the views this clip is on course to have PROJECTION_HOURS from now". `velocity` is
  # (newest − oldest snapshot views) / hours between them inside VELOCITY_WINDOW; it needs two
  # snapshots at least MIN_SPAN_HOURS apart (the poller runs every 3h) and is never negative.
  # With no usable snapshots velocity is 0 and the score IS view_count — the honest fallback, since
  # velocity cannot be reconstructed retroactively (the PUBG test run proved that). Deliberately
  # conservative: momentum is a bonus on top of an absolute audience, not a replacement, so one
  # burst cannot displace the channel's actual best clip.
  #
  # Two bounded queries, no N+1: the candidate pool (CANDIDATE_POOL clips by raw views,
  # index-served by farm_clips.broadcaster_twitch_id) and ONE aggregate over that pool's snapshots
  # (index-served by [farm_clip_id, captured_at]). A clip outside the pool can only be missed if its
  # PROJECTION_HOURS bonus exceeds its gap to the pool's tail — bounded by construction, and the
  # pool is generously wider than MAX_LIMIT.
  class ClipsQuery
    DEFAULT_LIMIT = 12
    MAX_LIMIT = 24
    CANDIDATE_POOL = 60
    PROJECTION_HOURS = 6
    VELOCITY_WINDOW = 48.hours
    MIN_SPAN_HOURS = 0.5

    def initialize(channel:, limit: DEFAULT_LIMIT)
      @channel = channel
      @limit = (limit.presence || DEFAULT_LIMIT).to_i.clamp(1, MAX_LIMIT)
    end

    def call
      candidates = FarmClip.where(broadcaster_twitch_id: @channel.twitch_id.to_s)
                           .order(view_count: :desc, twitch_created_at: :desc)
                           .limit(CANDIDATE_POOL)
                           .to_a
      return [] if candidates.empty?

      velocities = velocities_for(candidates.map(&:id))
      # clip_id breaks the last tie so the order is stable across identical requests.
      candidates.sort_by { |clip| [ -score(clip, velocities[clip.id].to_f), clip.clip_id ] }.first(@limit)
    end

    private

    # farm_clip_id => views/hour. One GROUP BY over the pool's snapshots; the first/last view counts
    # come out of the same pass via ordered array_agg instead of a second round trip per clip.
    def velocities_for(ids)
      FarmClipViewSnapshot
        .where(farm_clip_id: ids, captured_at: VELOCITY_WINDOW.ago..)
        .group(:farm_clip_id)
        .pluck(:farm_clip_id,
               Arel.sql("MIN(captured_at)"), Arel.sql("MAX(captured_at)"),
               Arel.sql("(array_agg(view_count ORDER BY captured_at ASC))[1]"),
               Arel.sql("(array_agg(view_count ORDER BY captured_at DESC))[1]"))
        .to_h { |id, first_at, last_at, first_views, last_views| [ id, velocity(first_at, last_at, first_views, last_views) ] }
    end

    def velocity(first_at, last_at, first_views, last_views)
      return 0.0 unless first_at && last_at && first_views && last_views

      hours = (last_at - first_at) / 1.hour.to_f
      return 0.0 if hours < MIN_SPAN_HOURS

      [ (last_views - first_views) / hours, 0.0 ].max
    end

    def score(clip, velocity)
      clip.view_count.to_i + (PROJECTION_HOURS * velocity)
    end
  end
end
