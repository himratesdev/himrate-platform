# frozen_string_literal: true

# TASK-031: Channel policy with track/untrack + serializer view selection.

class ChannelPolicy < ApplicationPolicy
  def index?
    registered?
  end

  def show?
    true
  end

  def create?
    registered?
  end

  def destroy?
    return false unless registered?

    channel_tracked?(record)
  end

  # TASK-031 FR-004: Track requires Premium, Business, or owns_channel (streamer data exchange)
  def track?
    return false unless registered?

    premium? || effective_business? || owns_channel?(record)
  end

  # TASK-031 FR-005: Untrack — any registered user can untrack their own tracked channel.
  # Ownership verified in controller (TrackedChannel.find_by user + channel).
  def untrack?
    registered?
  end

  # TASK-032 FR-002: Stream history — Premium tracked, Business, or Streamer own.
  def view_streams?
    return false unless registered?

    premium_access_for?(record)
  end

  # TASK-032 FR-004: Health Score — Streamer own, Premium tracked, Business.
  def view_health_score?
    return false unless registered?

    owns_channel?(record) || premium_access_for?(record)
  end

  # TASK-038 FR-036: Dismiss recommendation — same as view_health_score
  def dismiss_recommendation?
    view_health_score?
  end

  # TASK-038 FR-037: Recommendations visibility (Streamer own + subscribers).
  # BFT §5: Recommendations for streamer-tools roles. Premium/Business see as read-only for tracked channels.
  def can_receive_recommendations?
    return false unless registered?

    owns_channel?(record) || premium_access_for?(record)
  end

  # TASK-032 CR #4: show_trust? — always allows (headline for all), determines view level
  def show_trust?
    true
  end

  # TASK-035 FR-017: Trust history — Guest denied, Free 30m live only, Premium all
  def show_trust_history?
    registered?
  end

  # TASK-035 FR-035: Badge — Streamer own channel only
  def badge?
    return false unless registered?

    owns_channel?(record)
  end

  # TASK-035 FR-036: Channel Card — Streamer own channel only
  def card?
    return false unless registered?

    owns_channel?(record)
  end

  # TASK-032 CR #4: show_erv? — always allows (headline for all)
  def show_erv?
    true
  end

  # TASK-032 PG WARNING #2: Paywall for stream report — via Pundit (not controller)
  # Returns true if user can view the report for this channel.
  # Premium/Business/Streamer own: always. Free: only if live or TIME-lock window open.
  def view_report?
    return false unless registered?
    return true if premium_access_for?(record)
    return true if record.live?

    PostStreamWindowService.open?(record)
  end

  # TASK-085 FR-001/002/004 (US-001/002/003/013, EC-1): Stream Summary endpoint Pundit gating.
  # - Guest → controller authenticate_user! returns 401 ДО Pundit (BR-004 / US-013)
  # - Premium tracked / Business / Streamer own → always (no time window restriction per BR-002/003)
  # - Free + no completed streams → permit (controller returns 404 STREAM_NOT_FOUND per EC-1)
  # - Free + post_stream_window open → permit (BR-001 18h window)
  # - Free + window expired → deny (403 SUBSCRIPTION_REQUIRED)
  #
  # CR N-2 trade-off note: .exists? fires single SQL pre-service. LatestSummaryService then
  # re-queries to load actual stream. Total = 2 lightweight indexed queries per Free request.
  # Could optimize via passing scope through Pundit context, но это couples Pundit к service
  # internals (anti-pattern). Premium short-circuits before .exists? — no overhead.
  def view_latest_stream_summary?
    return false unless registered?
    return true if premium_access_for?(record)
    # No completed streams → 404 path (Pundit permits, service returns :not_found).
    return true unless record.streams.where.not(ended_at: nil).exists?

    PostStreamWindowService.open?(record)
  end

  # TASK-031 FR-008: Serializer view selection — single source of truth for tier-scoped fields.
  def serializer_view
    return :headline unless registered?

    if premium_access_for?(record)
      :full
    elsif record.live? || post_stream_window_open?(record)
      :drill_down
    else
      :headline
    end
  end

  # TASK-039 FR-012: Trends Tab historical access (7d/30d/60d/90d).
  # Premium tracked / Business / Streamer own (через Twitch OAuth data exchange).
  def view_trends_historical?
    return false unless registered?

    premium_access_for?(record) || streamer_on_channel?(record)
  end

  # TASK-039 FR-013: 365-day trends — Business tier only (включая team members).
  # Premium tracked видит максимум 90d; стример не получает 365d на своём канале.
  def view_365d_trends?
    effective_business?
  end

  # TASK-039 FR-014: Peer comparison (M3 Stability + Trust Index ranking).
  # PO clarification: Streamer на своём канале имеет полный доступ через data exchange.
  # Тождественно view_trends_historical? — оставлено отдельным predicate per SRS §2.2.
  def view_peer_comparison?
    return false unless registered?

    premium_access_for?(record) || streamer_on_channel?(record)
  end

  # TASK-032 CR #7: Public query methods (no more policy.send(:private_method))
  def premium_access?
    premium_access_for?(record)
  end

  def effective_business_access?
    effective_business?
  end

  def owns_channel_access?
    owns_channel?(record)
  end
end
