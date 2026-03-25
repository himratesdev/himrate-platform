# frozen_string_literal: true

module Api
  class BaseController < ActionController::API
    private

    def authenticate_user!
      token = request.headers["Authorization"]&.split(" ")&.last
      unless token
        render json: { error: "UNAUTHORIZED", message: "Bearer token required" }, status: :unauthorized
        return
      end

      payload = Auth::JwtService.decode(token)
      @current_user = User.find(payload[:sub])
    rescue Auth::AuthError => e
      render json: { error: "UNAUTHORIZED", message: e.message }, status: :unauthorized
    rescue ActiveRecord::RecordNotFound
      render json: { error: "UNAUTHORIZED", message: "User not found" }, status: :unauthorized
    end

    def current_user
      @current_user
    end
  end
end
