# frozen_string_literal: true

# TASK-031: Channels API — real logic replacing scaffold.
# GET /channels (tracked list), GET /channels/:id (tier-scoped TI/ERV),
# POST /channels/:id/track, DELETE /channels/:id/track.

module Api
  module V1
    class ChannelsController < Api::BaseController
      # T1-061 (DEC-5): :card is the universal card-object — guest-accessible (free layers 1+3),
      # so it joins :show in the optional-auth path instead of the required-auth path.
      before_action :authenticate_user!, except: %i[show card]
      before_action :authenticate_user_optional!, only: %i[show card]

      # CR PG-iter1: surface BillingNotConfigured как 402 Payment Required
      # (matches doc comment intent). Loud signal к operator, machine-readable
      # status code для frontend retry/fallback logic. Sentry catches via
      # ApplicationController error reporting independently.
      rescue_from "Api::V1::ChannelsController::BillingNotConfigured" do |e|
        Rails.error.report(e, context: { controller: "channels", action: action_name }, handled: true)
        render json: {
          error: "BILLING_NOT_CONFIGURED",
          message: I18n.t("channels.errors.billing_not_configured",
            default: "Subscription billing is not yet configured. Contact support.")
        }, status: :payment_required
      end

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
      # T1-061: universal layered card-object (extension + ЛК). Thin delegate to Cards::CardService
      # (gate-then-assemble; reputation from T1-065, never Trust(:full)). card? always allows; the
      # per-layer surface+role+payment gating lives in the service.
      def card
        channel = find_channel
        authorize channel, :card?

        payload = Cards::CardService.new(channel: channel, context: pundit_user).call
        payload[:badge_url] = "#{request.base_url}/api/v1/channels/#{channel.id}/badge.svg"
        payload[:public_url] = "https://himrate.com/channel/#{channel.login}"

        etag_value = Digest::MD5.hexdigest(payload.to_json)
        if stale?(etag: etag_value)
          render json: { data: payload }
        end
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
      # payment provider webhook), иначе 402 Payment Required (rescue_from в class header).
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
      # PR-A1 (EPIC SCALE ARCHITECTURE Step 2): peak_ccv / avg_ccv / duration_ms columns
      # dropped from streams. For ENDED streams source of truth is post_stream_reports.
      # CR-iter2 N-2: INNER JOIN (not LEFT) + ccv_avg NOT NULL filter — matches the
      # symmetric pattern used by Trends::Aggregation::DailyBuilder#ccv_aggregates so
      # totals reported here equal the daily aggregate sums (mid-race streams without PSR
      # are correctly excluded from "completed" stats — they show up once PostStreamWorker
      # finishes).
      def badge_html(channel, svg_url, ti_score)
        login = ERB::Util.html_escape(channel.login)
        %(<a href="https://himrate.com/channel/#{login}" target="_blank" rel="noopener">) +
          %(<img src="#{ERB::Util.html_escape(svg_url)}" alt="HimRate Trust Index: #{ti_score}" width="200" height="40" />) +
          %(</a>)
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
