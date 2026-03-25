# frozen_string_literal: true

module Api
  class BaseController < ActionController::API
    private

    def authenticate_user!
      token = request.headers["Authorization"]&.split(" ")&.last
      unless token
        Rails.logger.warn("Auth failed: no token from #{request.remote_ip}")
        render json: { error: "UNAUTHORIZED", message: "Bearer token required" }, status: :unauthorized
        return
      end

      payload = Auth::JwtService.decode(token)

      unless payload[:type] == "access"
        Rails.logger.warn("Auth failed: non-access token from #{request.remote_ip}")
        render json: { error: "UNAUTHORIZED", message: "Access token required" }, status: :unauthorized
        return
      end

      @current_user = User.find(payload[:sub])
    rescue Auth::AuthError => e
      Rails.logger.warn("Auth failed: #{e.class} from #{request.remote_ip}")
      render json: { error: "UNAUTHORIZED", message: e.message }, status: :unauthorized
    rescue ActiveRecord::RecordNotFound
      Rails.logger.warn("Auth failed: user not found from #{request.remote_ip}")
      render json: { error: "UNAUTHORIZED", message: "User not found" }, status: :unauthorized
    end

    def current_user
      @current_user
    end
  end
end
