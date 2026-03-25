# frozen_string_literal: true

module Webhooks
  class TwitchController < ActionController::API
    def create
      render json: { data: nil, meta: { status: "not_implemented", endpoint: "POST /webhooks/twitch" } }
    end
  end
end
