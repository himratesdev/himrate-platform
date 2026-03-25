# frozen_string_literal: true

module Webhooks
  class TwitchController < ActionController::API
    def create
      render json: { status: "not_implemented", endpoint: "POST /webhooks/twitch" }
    end
  end
end
