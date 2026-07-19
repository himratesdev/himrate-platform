# frozen_string_literal: true

Rails.application.routes.draw do
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # FR-003: Health endpoint with DB + Redis checks
  get "health" => "health#show"

  # TASK-013: Flipper UI (admin-only, HTTP Basic Auth)
  flipper_app = Flipper::UI.app(Flipper) do |builder|
    builder.use Rack::Auth::Basic, "Flipper" do |user, password|
      ActiveSupport::SecurityUtils.secure_compare(user, ENV.fetch("FLIPPER_UI_USER", "admin")) &
        ActiveSupport::SecurityUtils.secure_compare(
          password,
          ENV.fetch("FLIPPER_UI_PASSWORD") { Rails.env.production? ? raise("FLIPPER_UI_PASSWORD required") : "dev" }
        )
    end
  end
  mount flipper_app, at: "/admin/flipper"

  # PO Debug Dashboard — internal real-time observability for PO + T1 lane.
  # HTTP Basic Auth + Flipper :po_debug_dashboard flag. v0.1 Hot-Lite (3 blocks),
  # v1.0 fills 4 stubs + adds ActionCable broadcast.
  namespace :dashboard do
    get "po-debug", to: "po_debug#show", as: :po_debug, defaults: { format: :html }
    get "po-debug.json", to: "po_debug#show", defaults: { format: :json }
  end

  # Auth + API endpoints
  namespace :api do
    namespace :v1 do
      # TASK-090 OQ-4: maintenance health endpoint (always HTTP 200, even when
      # MAINTENANCE_MODE_ACTIVE=true). Excluded from MaintenanceMode middleware
      # so frontend can poll for window start/end.
      get "health/maintenance", to: "health/maintenance#show"

      # Auth (TASK-005 + TASK-007)
      post "auth/twitch", to: "auth#twitch"
      get "auth/twitch/callback", to: "auth#twitch_callback"
      post "auth/google", to: "auth#google"
      get "auth/google/callback", to: "auth#google_callback"
      post "auth/refresh", to: "auth#refresh"
      delete "auth/logout", to: "auth#logout"

      # LK-BACKEND Wave 1a — SaaS ЛК shell (auth optional): visibility gate + launch-notify.
      get "lk/status", to: "lk#status"
      post "lk/notify", to: "lk#notify"

      # TASK-031: User profile
      get "user/me", to: "users#me"
      patch "user/me", to: "users#update"

      # TASK-008 scaffold → TASK-031 real logic → TASK-032 analytics API
      resources :channels, only: %i[index show] do
        resource :trust, only: :show, controller: "trust" do
          # TASK-035 FR-017: Sparkline history
          get "history", on: :member, to: "trust#history"
        end
        # T1-065: Reputation history / trajectory (free trust-summary, card layer 3)
        get "reputation/history", to: "reputation#history"
        # TASK-035 FR-035: Badge embed (SVG route MUST be before badge to avoid format matching)
        get "badge.svg", to: "badges#show", defaults: { format: :svg }
        get "badge", to: "channels#badge"
        # TASK-035 FR-036: Channel Card
        get "card", to: "channels#card"
        resources :streams, only: %i[index] do
          # TASK-032 FR-003: Post-stream report
          get "report", on: :member, to: "streams#report"
          # TASK-085 FR-001: Latest stream summary (collection-level)
          get "latest/summary", on: :collection, to: "streams#latest_summary"
        end
        resource "bot-chain", only: :show, controller: "bot_chain", as: :bot_chain
        # TASK-032 FR-005: ERV
        resource :erv, only: :show, controller: "erv"

        # TASK-A1 (philosophy-v2): Trends API endpoints (M1 ERV / M2 TI / M3 Stability /
        # M4 Anomalies / M5 Components / M13 Categories / M14 Weekday)
        get "trends/erv", to: "channels/trends#erv"
        get "trends/trust_index", to: "channels/trends#trust_index"
        get "trends/stability", to: "channels/trends#stability"
        get "trends/anomalies", to: "channels/trends#anomalies"
        get "trends/components", to: "channels/trends#components"
        get "trends/categories", to: "channels/trends#categories"
        get "trends/patterns/weekday", to: "channels/trends#weekday_patterns"

        # TASK-031: Track/untrack channel
        post "track", to: "channels#track"
        delete "track", to: "channels#untrack"

        # TASK-034 FR-025: Request tracking for untracked channels
        post "request_tracking", to: "tracking_requests#create"

        # TASK-022: Extension-side GQL data ingestion
        post "gql_data", to: "gql_data#create"
      end
      resources :subscriptions, only: %i[index create destroy]
      # TASK-036: Watchlists CRUD + channels + tags
      resources :watchlists, only: %i[index create update destroy] do
        resources :channels, only: %i[index create destroy], controller: "watchlist_channels" do
          member do
            patch :move
            patch :meta
          end
        end
      end
      get "watchlists/tags", to: "watchlists#tags"

      # TASK-018: Auth events tracking (observability)
      post "analytics/auth_events", to: "auth_events#create"

      # TASK-110 FR-008..018: Twitch Clips on-demand transcripts (S2 surface)
      post "clip_transcripts/request", to: "clip_transcripts#request_transcript"
      get "clip_transcripts/remaining", to: "clip_transcripts#remaining"
      get "clip_transcripts/by_broadcaster/:broadcaster_id", to: "clip_transcripts#by_broadcaster"
      get "clip_transcripts/:clip_id", to: "clip_transcripts#show", constraints: { clip_id: %r{[^/]+} }

      # TASK-110 FR-021..025: Cross-device sync API (S3 surface)
      post "sync/events", to: "sync#push"
      get "sync/snapshot", to: "sync#snapshot"

      # TASK-110 FR-006..007: React fiber chat capture batch ingest
      post "chat/messages", to: "chat_ingest#create"

      # TASK-113 BE-2/BE-3/BE-4/BE-5: Personal Viewer Analytics (self-analytics, JWT + ownership, all-free)
      namespace :me do
        get "analytics/overview", to: "analytics#overview"
        get "analytics/communities", to: "analytics#communities"
        get "analytics/engagement_log", to: "analytics#engagement_log"
        get "analytics/supporter", to: "analytics#supporter"
        get "analytics/reflection", to: "analytics#reflection"
        get "analytics/patterns", to: "analytics#patterns"
        get "analytics/cohort", to: "analytics#cohort"
        post "analytics/engagement", to: "analytics#engagement"
        # BE-5 M13 Export (FR-012): async JSON archive (POST + GET /:id download)
        post "analytics/export", to: "analytics#export"
        get "analytics/export/:id", to: "analytics#export_download"
        # BE-5 M15 Privacy
        get "privacy", to: "privacy#show"
        put "privacy", to: "privacy#update"
        # TASK-113 Δ-1 Wave 1 (FR-016): cold-start enrollment backfill state + extension payload + per-source retry.
        get "analytics/cold_start/state", to: "analytics/cold_start#state"
        post "analytics/cold_start/subs_payload", to: "analytics/cold_start#subs_payload"
        post "analytics/cold_start/retry", to: "analytics/cold_start#retry_source"
        # LK-BACKEND Wave 1b (screen 01 Home): recent-opened channels + live-from-watchlists.
        get "home/recent_channels", to: "home#recent"
        post "home/recent_channels", to: "home#track_recent"
        get "home/live_channels", to: "home#live_channels"
      end
      # BE-5 M13 minimal soft-delete (PO directive 2026-05-28) — out-of-namespace для чистого DELETE /me
      delete "me", to: "me/privacy#destroy_account"

      # LK-BACKEND Wave 2 (screen 24): brand-side audience overlap (brand-gated, chat-presence graph).
      namespace :brand do
        get "overlap", to: "overlap#index"
      end
    end
  end

  # TASK-032 FR-012: Action Cable WebSocket mount
  mount ActionCable.server => "/cable"

  # Webhooks (public, no auth)
  post "webhooks/twitch", to: "webhooks/twitch#create"

  # Render dynamic PWA files from app/views/pwa/* (remember to link manifest in application.html.erb)
  # get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
  # get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker

  # --- Public marketing landing (TASK-060) ---
  # Public, unauthenticated HTML pages (Pencil-export port). API (api/v1/*) is
  # unaffected. Legal pages + responsive merge land in later phases.
  root "pages#index"
  get "streamers",   to: "pages#streamers"
  get "brands",      to: "pages#brands"
  get "viewers",     to: "pages#viewers"
  get "methodology", to: "pages#methodology"
end
