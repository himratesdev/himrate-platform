# frozen_string_literal: true

# Shared cold-miss warming for the social-profile endpoints (streamer profile + attribution). On a
# cache miss the caller reports `pending` and calls this to enqueue exactly one ProfileRefreshWorker,
# deduped by a pending flag — the Grow/Moments on-demand pattern, zero recurring load. Both endpoints
# read the SAME worker-warmed cache, so they share one warm path (no drift). Descriptive data only.
module SocialProfileWarming
  private

  def warm_social_profile(login)
    pending = ::SocialAnalytics::ProfileRefreshWorker.pending_key(login)
    return if Rails.cache.exist?(pending)

    Rails.cache.write(pending, true, expires_in: ::SocialAnalytics::ProfileRefreshWorker::PENDING_TTL)
    ::SocialAnalytics::ProfileRefreshWorker.perform_async(login)
  end
end
