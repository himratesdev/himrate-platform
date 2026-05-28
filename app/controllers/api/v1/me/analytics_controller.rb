# frozen_string_literal: true

module Api
  module V1
    module Me
      # TASK-113 BE-2 (FR-001..005, M1-M5): Personal Viewer Analytics overview. Thin: params → service →
      # render (эталон Api::V1::Channels::TrendsController). JWT (authenticate_user!) + Pundit ownership
      # (свои данные, НЕ paywall — PVA all-free). Feature за Flipper :pva. Redis hot-cache 5 мин (SRS §9).
      class AnalyticsController < Api::BaseController
        MAX_BATCH = 500

        before_action :authenticate_user!
        before_action :ensure_pva_enabled

        rescue_from PersonalAnalytics::Api::OverviewService::InvalidWindow,
          PersonalAnalytics::Api::CommunitiesService::InvalidWindow,
          PersonalAnalytics::Api::EngagementLogService::InvalidType,
          PersonalAnalytics::Api::ReflectionService::InvalidWeek,
          with: :render_invalid_params

        # GET /api/v1/me/analytics/overview?window=7d|30d|90d|365d|all (M1-M5)
        def overview
          authorize current_user, :overview?, policy_class: PersonalAnalyticsPolicy
          render_cached("overview", params[:window]) do
            PersonalAnalytics::Api::OverviewService.new(user: current_user, window: params[:window]).call
          end
        end

        # GET /api/v1/me/analytics/communities?window=... (M6)
        def communities
          authorize current_user, :overview?, policy_class: PersonalAnalyticsPolicy
          render_cached("communities", params[:window]) do
            PersonalAnalytics::Api::CommunitiesService.new(user: current_user, window: params[:window]).call
          end
        end

        # GET /api/v1/me/analytics/engagement_log?type=sub|cheer|follow|hype_contribution (M7)
        def engagement_log
          authorize current_user, :overview?, policy_class: PersonalAnalyticsPolicy
          render_cached("engagement_log", "#{params[:type]}:#{params[:before]}") do
            PersonalAnalytics::Api::EngagementLogService.new(
              user: current_user, type: params[:type], before: params[:before]
            ).call
          end
        end

        # GET /api/v1/me/analytics/supporter (M9 tier + M8 tenure)
        def supporter
          authorize current_user, :overview?, policy_class: PersonalAnalyticsPolicy
          render_cached("supporter", nil) do
            PersonalAnalytics::Api::SupporterService.new(user: current_user).call
          end
        end

        # GET /api/v1/me/analytics/reflection?week=YYYY-MM-DD&archive=true (M10)
        def reflection
          authorize current_user, :overview?, policy_class: PersonalAnalyticsPolicy
          render_cached("reflection", "#{params[:week]}:#{params[:archive]}") do
            PersonalAnalytics::Api::ReflectionService.new(
              user: current_user, week: params[:week], archive: params[:archive]
            ).call
          end
        end

        # GET /api/v1/me/analytics/patterns (M11)
        def patterns
          authorize current_user, :overview?, policy_class: PersonalAnalyticsPolicy
          render_cached("patterns", nil) do
            PersonalAnalytics::Api::PatternsService.new(user: current_user).call
          end
        end

        # GET /api/v1/me/analytics/cohort (M12)
        def cohort
          authorize current_user, :overview?, policy_class: PersonalAnalyticsPolicy
          render_cached("cohort", nil) do
            PersonalAnalytics::Api::CohortService.new(user: current_user).call
          end
        end

        # POST /api/v1/me/analytics/export — M13 async JSON archive (FR-012).
        # 202 + job_id; результат лежит в Rails.cache 24ч и доступен по GET /export/:job_id.
        def export
          authorize current_user, :export?, policy_class: PersonalAnalyticsPolicy
          job_id = SecureRandom.uuid
          PersonalAnalytics::ExportWorker.perform_async(current_user.id, job_id)
          render json: { job_id: job_id, status: "queued",
                         poll_url: "/api/v1/me/analytics/export/#{job_id}" }, status: :accepted
        end

        # GET /api/v1/me/analytics/export/:id — M13 download archive (FR-012).
        # 200 + payload если готов; 404 если истёк/не существует; 202 если ещё в очереди (best-effort).
        def export_download
          authorize current_user, :download_export?, policy_class: PersonalAnalyticsPolicy
          raw = Rails.cache.read(PersonalAnalytics::ExportWorker.cache_key(params[:id]))
          return render(json: { error: "EXPORT_NOT_READY" }, status: :not_found) unless raw

          # Authorization-by-payload: гарантируем что job_id принадлежит текущему юзеру.
          data = JSON.parse(raw)
          return render(json: { error: "EXPORT_NOT_READY" }, status: :not_found) if data["user"]&.dig("id") != current_user.id

          render json: data
        end

        # POST /api/v1/me/analytics/engagement — client-capture ingest (M7 discrete events + M6 chat snapshots).
        # Async (Sidekiq) — синхронный ответ не ждёт записи. Idempotent downstream (event_hash dedup /
        # snapshot upsert-replace) → безопасно при ретраях клиента.
        def engagement
          authorize current_user, :ingest?, policy_class: PersonalAnalyticsPolicy
          events = batch_param(:events)
          chat_activity = batch_param(:chat_activity)
          tenure = batch_param(:tenure)
          PersonalAnalytics::EngagementIngestWorker.perform_async(current_user.id, events) if events.any?
          PersonalAnalytics::ChatActivityIngestWorker.perform_async(current_user.id, chat_activity) if chat_activity.any?
          PersonalAnalytics::TenureIngestWorker.perform_async(current_user.id, tenure) if tenure.any?
          render json: { queued: { events: events.size, chat_activity: chat_activity.size, tenure: tenure.size } },
            status: :accepted
        end

        private

        # Plain string-keyed hashes (Sidekiq strict_args требует JSON-native — не HashWithIndifferentAccess),
        # capped. Воркеры = validation boundary (drop невалидные).
        def batch_param(key)
          Array(params[key]).first(MAX_BATCH).map { |item| item.respond_to?(:to_unsafe_h) ? item.to_unsafe_h.to_hash : item }
        end

        # PVA за kill-switch :pva (OFF пока не выпущена) — endpoint недоступен пока флаг off.
        def ensure_pva_enabled
          return if Flipper.enabled?(:pva)

          render json: { error: "NOT_FOUND" }, status: :not_found
        end

        # Redis hot-cache (SRS §9, 5 мин + race_condition_ttl). Ключ = endpoint + user + suffix (window/type).
        def render_cached(endpoint, suffix)
          key = "pva:#{endpoint}:#{current_user.id}:#{suffix.presence || 'default'}"
          render json: Rails.cache.fetch(key, expires_in: 5.minutes, race_condition_ttl: 10.seconds) { yield }
        end

        # UPPER_SNAKE error code (консистентно с NOT_FOUND выше + Api::BaseController codes — CR Nit-2).
        def render_invalid_params(exception)
          render json: { error: "INVALID_PARAMS", message: exception.message }, status: :bad_request
        end
      end
    end
  end
end
