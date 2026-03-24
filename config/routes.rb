# frozen_string_literal: true

Rails.application.routes.draw do
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # FR-003: Health endpoint with DB + Redis checks
  get "health" => "health#show"

  # TASK-005: Auth endpoints
  namespace :api do
    namespace :v1 do
      post "auth/twitch", to: "auth#twitch"
      get "auth/twitch/callback", to: "auth#twitch_callback"
      post "auth/google", to: "auth#google"
      get "auth/google/callback", to: "auth#google_callback"
      post "auth/refresh", to: "auth#refresh"
      delete "auth/logout", to: "auth#logout"
    end
  end

  # Render dynamic PWA files from app/views/pwa/* (remember to link manifest in application.html.erb)
  # get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
  # get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker

  # Defines the root path route ("/")
  # root "posts#index"
end
