# frozen_string_literal: true

# TASK-031: Channels API — real logic replacing scaffold.
# GET /channels (tracked list), GET /channels/:id (tier-scoped TI/ERV),
# POST /channels/:id/track, DELETE /channels/:id/track.

module Api
  module V1
    class ChannelsController < Api::BaseController
      before_action :authenticate_user!, except: :show
      before_action :authenticate_user_optional!, only: :show

      # FR-003/010: GET /api/v1/channels — tracked channels list (paginated)
      def index
        authorize Channel

        tracked = current_user.tracked_channels
          .where(tracking_enabled: true)
          .includes(channel: [ :trust_index_histories, :streams ])
          .order(added_at: :desc)

        page = (params[:page] || 1).to_i
        per_page = [ (params[:per_page] || default_per_page).to_i, 100 ].min
        total = tracked.count
        paginated = tracked.offset((page - 1) * per_page).limit(per_page)

        channels = paginated.map(&:channel)
        watched_ids = current_user.tracked_channels.where(tracking_enabled: true).pluck(:channel_id).to_set
        render json: {
          data: channels.map { |ch| ChannelBlueprint.render_as_hash(ch, view: :headline, current_user: current_user, watched_channel_ids: watched_ids) },
          meta: { page: page, per_page: per_page, total: total, total_pages: (total.to_f / per_page).ceil }
        }
      end

      # FR-002/007/008/011: GET /api/v1/channels/:id — channel + TI/ERV (tier-scoped)
      def show
        channel = find_channel
        authorize channel

        view = serializer_view(channel)
        render json: {
          data: ChannelBlueprint.render_as_hash(channel, view: view, current_user: current_user)
        }
      end

      # FR-004: POST /api/v1/channels/:id/track — start tracking
      #
      # BUG-012: TrackedChannel ДОЛЖЕН ссылаться на Subscription через subscription_id —
      # ChannelPolicy#channel_tracked? делает INNER JOIN. NOT NULL constraint
      # (migration 20260425100002) enforces invariant. Controller now ensures
      # active Subscription exists для current_user (auto-create если missing —
      # actual billing integration handled через payment provider webhooks separately;
      # auto-creation покрывает manual API-driven tracking).
      def track
        channel = Channel.find(params[:channel_id] || params[:id])
        authorize channel, :track?

        existing = TrackedChannel.find_by(user: current_user, channel: channel)

        if existing&.tracking_enabled?
          render json: { error: "ALREADY_TRACKED", message: I18n.t("channels.errors.already_tracked", default: "Channel is already tracked") },
            status: :conflict
          return
        end

        # CR N-1: атомарный wrap — Subscription auto-create + TC link выполняются
        # в одной transaction. Если TC.save fails (e.g. unexpected validation), orphan
        # Subscription rolled back. Belt-and-suspenders.
        ActiveRecord::Base.transaction do
          sub = ensure_active_subscription_for(current_user)

          if existing
            existing.update!(tracking_enabled: true, added_at: Time.current, subscription: sub)
          else
            TrackedChannel.create!(user: current_user, channel: channel, tracking_enabled: true, added_at: Time.current, subscription: sub)
          end
          channel.update!(is_monitored: true) unless channel.is_monitored
        end

        render json: { data: ChannelBlueprint.render_as_hash(channel, view: :headline, current_user: current_user) }, status: :created
      end

      # FR-005: DELETE /api/v1/channels/:id/track — stop tracking
      def untrack
        channel = Channel.find(params[:channel_id] || params[:id])
        authorize channel, :untrack?

        tracked = TrackedChannel.find_by(user: current_user, channel: channel, tracking_enabled: true)

        unless tracked
          render json: { error: "CHANNEL_NOT_TRACKED", message: I18n.t("channels.errors.not_tracked", default: "Channel is not tracked") },
            status: :not_found
          return
        end

        tracked.update!(tracking_enabled: false)

        render json: { status: "untracked", channel_id: channel.id }
      end

      # TASK-035 FR-035: GET /api/v1/channels/:id/badge — SVG badge embed code
      def badge
        channel = find_channel
        authorize channel, :badge?

        ti = channel.trust_index_histories.order(calculated_at: :desc).first
        ti_score = ti&.trust_index_score&.to_f&.round(0) || 0
        erv_data = ti ? TrustIndex::ErvCalculator.compute(
          ti_score: ti.trust_index_score.to_f,
          ccv: ti.ccv.to_i,
          confidence: ti.confidence.to_f
        ) : {}

        color = erv_data[:label_color] || "grey"
        svg_url = "#{request.base_url}/api/v1/channels/#{channel.id}/badge.svg"

        render json: {
          data: {
            html: badge_html(channel, svg_url, ti_score),
            markdown: "[![HimRate](#{svg_url})](https://himrate.com/channel/#{channel.login})",
            bbcode: "[url=https://himrate.com/channel/#{channel.login}][img]#{svg_url}[/img][/url]",
            svg_url: svg_url,
            ti_score: ti_score,
            color: color
          }
        }
      end

      # TASK-035 FR-036: GET /api/v1/channels/:id/card — Channel Card data
      def card
        channel = find_channel
        authorize channel, :card?

        trust = Trust::ShowService.new(channel: channel, view: :full, user: current_user).call

        completed_streams = channel.streams.where.not(ended_at: nil)
        recent = completed_streams.order(ended_at: :desc).limit(5)

        # S2 fix: prefetch TI records for all recent streams in one query (no N+1)
        recent_ti = prefetch_ti_for_streams(recent, channel.id)

        render json: {
          data: {
            channel: {
              login: channel.login,
              display_name: channel.display_name,
              avatar_url: channel.profile_image_url,
              partner_status: channel.broadcaster_type,
              created_at: channel.created_at.iso8601,
              followers_count: channel.followers_total
            },
            trust: trust.slice(:ti_score, :classification, :erv_percent, :erv_label, :erv_label_color),
            health_score: trust[:health_score],
            reputation: trust[:streamer_reputation],
            stats: stream_stats(completed_streams, channel),
            recent_streams: recent.map { |s| format_stream(s, recent_ti[s.id]) },
            badge_url: "#{request.base_url}/api/v1/channels/#{channel.id}/badge.svg",
            public_url: "https://himrate.com/channel/#{channel.login}"
          }
        }
      end

      private

      # BUG-012: returns active premium/business Subscription для user, creates
      # если none AND билинг auto-create flag enabled.
      #
      # CR N-4: production launch checklist должен gate'ить /track endpoint behind
      # billing webhook integration. Flipper hook flag billing_auto_subscription_creation
      # (registered as HOOK_FLAG, default OFF) controls whether controller auto-creates
      # Subscription. Dev/staging: enable flag для seamless API-driven testing.
      # Production: flag remains OFF — pre-existing Subscription required (created by
      # payment provider webhook), иначе 402 Payment Required.
      class BillingNotConfigured < StandardError; end

      def ensure_active_subscription_for(user)
        existing = user.subscriptions.where(is_active: true).first
        return existing if existing

        unless Flipper.enabled?(:billing_auto_subscription_creation)
          raise BillingNotConfigured,
            "User #{user.id} has no active Subscription — billing webhook not received. " \
            "Auto-creation disabled (enable Flipper :billing_auto_subscription_creation для dev/staging)."
        end

        Subscription.create!(
          user: user,
          tier: user.tier,
          plan_type: "per_channel",
          is_active: true,
          started_at: Time.current
        )
      end

      # W1 fix: single aggregate query instead of 3 separate (count + avg + max)
      def stream_stats(completed_streams, channel)
        agg = completed_streams
          .pick(
            Arel.sql("COUNT(*)"),
            Arel.sql("AVG(avg_ccv)"),
            Arel.sql("MAX(peak_ccv)"),
            Arel.sql("AVG(duration_ms)")
          )

        total = agg[0].to_i
        {
          total_streams: total,
          avg_ccv: agg[1]&.to_i,
          peak_ccv: agg[2]&.to_i,
          avg_duration_hours: agg[3] ? (agg[3].to_f / 3_600_000).round(1) : nil,
          streams_per_week: streams_per_week(channel)
        }
      end

      def badge_html(channel, svg_url, ti_score)
        login = ERB::Util.html_escape(channel.login)
        %(<a href="https://himrate.com/channel/#{login}" target="_blank" rel="noopener">) +
          %(<img src="#{ERB::Util.html_escape(svg_url)}" alt="HimRate Trust Index: #{ti_score}" width="200" height="40" />) +
          %(</a>)
      end

      def streams_per_week(channel)
        first_stream = channel.streams.order(:started_at).first
        return nil unless first_stream

        weeks = [ (Time.current - first_stream.started_at) / 1.week, 1 ].max
        total = channel.streams.where.not(ended_at: nil).count
        (total.to_f / weeks).round(1)
      end

      # S2 fix: single query for all recent streams' TI records (no N+1)
      def prefetch_ti_for_streams(streams, channel_id)
        return {} if streams.empty?

        min_start = streams.map(&:started_at).min
        max_end = streams.map { |s| s.ended_at || Time.current }.max

        all_ti = TrustIndexHistory
          .where(channel_id: channel_id)
          .where(calculated_at: min_start..max_end)
          .order(calculated_at: :desc)

        streams.to_h do |s|
          ti = all_ti.find { |t| t.calculated_at.between?(s.started_at, s.ended_at || Time.current) }
          [ s.id, ti ]
        end
      end

      def format_stream(stream, ti = nil)
        {
          date: stream.started_at.iso8601,
          duration_hours: stream.duration_ms ? (stream.duration_ms / 3_600_000.0).round(1) : nil,
          peak_ccv: stream.peak_ccv,
          avg_ccv: stream.avg_ccv,
          ti_score: ti&.trust_index_score&.to_f&.round(1),
          erv_percent: ti&.erv_percent&.to_f&.round(1)
        }
      end

      # FR-007/011: Find channel by UUID, login, or twitch_id
      def find_channel
        identifier = params[:channel_id] || params[:id]

        if params[:twitch_id].present?
          Channel.find_by!(twitch_id: params[:twitch_id])
        elsif params[:login].present?
          Channel.find_by!(login: params[:login])
        elsif identifier =~ /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i
          Channel.find(identifier)
        else
          Channel.find_by!(login: identifier)
        end
      rescue ActiveRecord::RecordNotFound
        raise
      end

      # FR-008: View selection in policy logic (not hardcoded in controller)
      def serializer_view(channel)
        policy = ChannelPolicy.new(current_user, channel)
        policy.serializer_view
      end

      def default_per_page
        SignalConfiguration.value_for("api", "default", "channels_per_page").to_i
      rescue SignalConfiguration::ConfigurationMissing
        20
      end
    end
  end
end
