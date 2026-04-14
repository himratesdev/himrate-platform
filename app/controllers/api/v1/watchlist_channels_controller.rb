# frozen_string_literal: true

# TASK-036: Channels within a watchlist — add/remove/move/list/meta.
# Nested under /watchlists/:watchlist_id/channels.

module Api
  module V1
    class WatchlistChannelsController < Api::BaseController
      before_action :authenticate_user!
      before_action :set_watchlist

      # FR-008+FR-010+FR-022+FR-026+FR-028: List enriched channels
      def index
        authorize @watchlist, :show?

        filters = filter_params
        sort = params[:sort] || "erv_desc"

        # FR-014: Filters are Premium/Business only
        if filters.any? && !can_filter?
          render json: { error: "SUBSCRIPTION_REQUIRED", message: "Filters require Premium or Business" },
            status: :forbidden
          return
        end

        svc = ::Watchlists::EnrichmentService.new(
          watchlist: @watchlist, user: current_user, filters: filters, sort: sort
        )

        render json: {
          data: svc.call,
          meta: { total: @watchlist.channels_count, watchlist_name: @watchlist.name }
        }
      end

      # FR-005: Add channel to watchlist
      def create
        authorize @watchlist, :update?

        if @watchlist.full?
          render json: { error: "LIMIT_REACHED", message: "Watchlist limit reached (#{Watchlist::MAX_CHANNELS_PER_LIST})" },
            status: :unprocessable_entity
          return
        end

        channel = find_channel
        wc = @watchlist.watchlist_channels.build(channel: channel, added_at: Time.current)

        if wc.save
          render json: { data: { channel_id: channel.id, watchlist_id: @watchlist.id } }, status: :created
        else
          render json: { error: "ALREADY_IN_LIST", message: "Channel already in this watchlist" }, status: :conflict
        end
      end

      # FR-006: Remove channel from watchlist
      def destroy
        authorize @watchlist, :update?

        wc = @watchlist.watchlist_channels.find_by!(channel_id: params[:id])
        wc.destroy!

        render json: { status: "removed", channel_id: params[:id] }
      end

      # FR-007: Move channel to another watchlist
      def move
        authorize @watchlist, :update?

        target = current_user.watchlists.find(params[:target_watchlist_id])
        wc = @watchlist.watchlist_channels.find_by!(channel_id: params[:id])

        if target.id == @watchlist.id
          render json: { error: "ALREADY_IN_LIST", message: "Channel already in this watchlist" }, status: :conflict
          return
        end

        if target.full?
          render json: { error: "LIMIT_REACHED", message: "Target watchlist is full" }, status: :unprocessable_entity
          return
        end

        WatchlistChannel.transaction do
          wc.destroy!
          target.watchlist_channels.create!(channel_id: wc.channel_id, added_at: Time.current)
        end

        render json: { status: "moved", channel_id: wc.channel_id, target_watchlist_id: target.id }
      end

      # FR-009: Update tags/notes for a channel in this watchlist
      def meta
        authorize @watchlist, :update?

        tn = WatchlistTagsNote.find_or_initialize_by(watchlist: @watchlist, channel_id: params[:id])
        tn.assign_attributes(meta_params)
        tn.added_at ||= Time.current

        if tn.save
          render json: { data: { tags: tn.tags, notes: tn.notes } }
        else
          render json: { error: "VALIDATION_ERROR", message: tn.errors.full_messages.join(", ") },
            status: :unprocessable_entity
        end
      end

      private

      def set_watchlist
        @watchlist = current_user.watchlists.find(params[:watchlist_id])
      end

      def find_channel
        if params[:channel_login].present?
          Channel.find_by!(login: params[:channel_login])
        else
          Channel.find(params[:channel_id])
        end
      end

      def filter_params
        params.permit(:erv_min, :erv_max, :ti_min, :is_live).to_h.compact_blank
      end

      def meta_params
        params.permit(:notes, tags: [])
      end

      def can_filter?
        current_user.subscriptions.where(status: "active").exists?
      end
    end
  end
end
