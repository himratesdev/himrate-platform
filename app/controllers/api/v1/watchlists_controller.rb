# frozen_string_literal: true

# TASK-036: Watchlists CRUD — real logic replacing scaffold.
# GET /watchlists (list + batch stats), POST /watchlists (create),
# PATCH /watchlists/:id (rename), DELETE /watchlists/:id (delete + auto-recreate).
# GET /watchlists/tags (tag autocomplete).

module Api
  module V1
    class WatchlistsController < Api::BaseController
      before_action :authenticate_user!
      before_action :set_watchlist, only: %i[update destroy]

      # FR-001+FR-023: List watchlists with channel counts and batch stats (4 queries, not 4×N)
      def index
        authorize Watchlist
        Watchlist.ensure_default_for(current_user)

        watchlists = current_user.watchlists.ordered.to_a
        stats_map = ::Watchlists::BatchStatsService.new(watchlists: watchlists, user: current_user).call

        render json: {
          data: watchlists.map { |wl| serialize_watchlist(wl, stats_map[wl.id]) }
        }
      end

      # FR-002 + S3: Create watchlist (max 50 per user)
      def create
        authorize Watchlist

        if current_user.watchlists.count >= Watchlist::MAX_WATCHLISTS_PER_USER
          render json: { error: "WATCHLIST_LIMIT_REACHED", message: I18n.t("watchlists.errors.watchlist_limit") },
            status: :unprocessable_entity
          return
        end

        position = (current_user.watchlists.maximum(:position) || -1) + 1
        watchlist = current_user.watchlists.build(
          name: watchlist_params[:name],
          position: position
        )

        if watchlist.save
          render json: { data: serialize_watchlist(watchlist) }, status: :created
        else
          render json: { error: "VALIDATION_ERROR", message: watchlist.errors.full_messages.join(", ") },
            status: :unprocessable_entity
        end
      end

      # FR-003: Rename watchlist
      def update
        authorize @watchlist

        if @watchlist.update(name: watchlist_params[:name])
          render json: { data: serialize_watchlist(@watchlist) }
        else
          render json: { error: "VALIDATION_ERROR", message: @watchlist.errors.full_messages.join(", ") },
            status: :unprocessable_entity
        end
      end

      # FR-004: Delete watchlist + auto-recreate default if last
      def destroy
        authorize @watchlist

        @watchlist.destroy!
        Watchlist.ensure_default_for(current_user)

        render json: { status: "deleted", watchlist_id: @watchlist.id }
      end

      # FR-019: Tag autocomplete
      def tags
        authorize Watchlist, :index?

        query = params[:q].to_s.strip
        return render(json: { data: [] }) if query.length < 1

        watchlist_ids = current_user.watchlists.pluck(:id)
        return render(json: { data: [] }) if watchlist_ids.empty?

        tags = WatchlistTagsNote
          .where(watchlist_id: watchlist_ids)
          .where("EXISTS (SELECT 1 FROM jsonb_array_elements_text(tags) t WHERE t ILIKE ?)", "#{query}%")
          .pluck(Arel.sql("DISTINCT jsonb_array_elements_text(tags)"))
          .select { |t| t.downcase.start_with?(query.downcase) }
          .first(10)

        render json: { data: tags }
      end

      private

      def set_watchlist
        @watchlist = current_user.watchlists.find(params[:id])
      end

      def watchlist_params
        params.require(:watchlist).permit(:name)
      end

      def serialize_watchlist(watchlist, stats = nil)
        stats ||= ::Watchlists::EnrichmentService.new(watchlist: watchlist, user: current_user).stats

        {
          id: watchlist.id,
          name: watchlist.name,
          channels_count: stats[:total],
          position: watchlist.position,
          stats: stats,
          created_at: watchlist.created_at.iso8601
        }
      end
    end
  end
end
