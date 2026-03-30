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
          .includes(channel: { trust_index_histories: [], streams: [] })
          .order(added_at: :desc)

        page = (params[:page] || 1).to_i
        per_page = [ (params[:per_page] || default_per_page).to_i, 100 ].min
        total = tracked.count
        paginated = tracked.offset((page - 1) * per_page).limit(per_page)

        channels = paginated.map(&:channel)
        render json: {
          data: channels.map { |ch| ChannelBlueprint.render_as_hash(ch, view: :headline, current_user: current_user) },
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
      def track
        channel = Channel.find(params[:channel_id] || params[:id])
        authorize channel, :track?

        if TrackedChannel.exists?(user: current_user, channel: channel)
          render json: { error: "ALREADY_TRACKED", message: I18n.t("channels.errors.already_tracked", default: "Channel is already tracked") },
            status: :conflict
          return
        end

        TrackedChannel.create!(user: current_user, channel: channel, tracking_enabled: true, added_at: Time.current)
        channel.update!(is_monitored: true) unless channel.is_monitored

        render json: { data: ChannelBlueprint.render_as_hash(channel, view: :headline, current_user: current_user) }, status: :created
      end

      # FR-005: DELETE /api/v1/channels/:id/track — stop tracking
      def untrack
        channel = Channel.find(params[:channel_id] || params[:id])
        authorize channel, :untrack?

        tracked = TrackedChannel.find_by(user: current_user, channel: channel)

        unless tracked
          render json: { error: "CHANNEL_NOT_TRACKED", message: I18n.t("channels.errors.not_tracked", default: "Channel is not tracked") },
            status: :not_found
          return
        end

        tracked.destroy!

        render json: { status: "untracked", channel_id: channel.id }
      end

      private

      # FR-007/011: Find channel by UUID, login, or twitch_id
      def find_channel
        if params[:twitch_id].present?
          Channel.find_by!(twitch_id: params[:twitch_id])
        elsif params[:login].present?
          Channel.find_by!(login: params[:login])
        elsif params[:id] =~ /\A[0-9a-f]{8}-/
          Channel.find(params[:channel_id] || params[:id])
        else
          Channel.find_by!(login: params[:id])
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
