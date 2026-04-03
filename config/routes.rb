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

  # Auth + API endpoints
  namespace :api do
    namespace :v1 do
      # Auth (TASK-005 + TASK-007)
      post "auth/twitch", to: "auth#twitch"
      get "auth/twitch/callback", to: "auth#twitch_callback"
      post "auth/google", to: "auth#google"
      get "auth/google/callback", to: "auth#google_callback"
      post "auth/refresh", to: "auth#refresh"
      delete "auth/logout", to: "auth#logout"

      # TASK-031: User profile
      get "user/me", to: "users#me"
      patch "user/me", to: "users#update"

      # TASK-008 scaffold → TASK-031 real logic → TASK-032 analytics API
      resources :channels, only: %i[index show] do
        resource :trust, only: :show, controller: "trust"
        resources :streams, only: %i[index] do
          # TASK-032 FR-003: Post-stream report
          get "report", on: :member, to: "streams#report"
        end
        resource "bot-chain", only: :show, controller: "bot_chain", as: :bot_chain
        # TASK-032 FR-004: Health Score
        resource :health_score, only: :show, controller: "health_scores"
        # TASK-032 FR-005: ERV
        resource :erv, only: :show, controller: "erv"

        # TASK-031: Track/untrack channel
        post "track", to: "channels#track"
        delete "track", to: "channels#untrack"

        # TASK-034 FR-025: Request tracking for untracked channels
        post "request_tracking", to: "tracking_requests#create"

        # TASK-022: Extension-side GQL data ingestion
        post "gql_data", to: "gql_data#create"
      end
      resources :subscriptions, only: %i[index create destroy]
      resources :watchlists, only: %i[index create destroy]

      # TASK-018: Auth events tracking (observability)
      post "analytics/auth_events", to: "auth_events#create"
    end
  end

  # TASK-032 FR-012: Action Cable WebSocket mount
  mount ActionCable.server => "/cable"

  # Webhooks (public, no auth)
  post "webhooks/twitch", to: "webhooks/twitch#create"

  # Render dynamic PWA files from app/views/pwa/* (remember to link manifest in application.html.erb)
  # get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
  # get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker

  # Defines the root path route ("/")
  # root "posts#index"
end
