# frozen_string_literal: true

module Auth
  class JwtService
    SECRET = ENV.fetch("JWT_SECRET") { Rails.application.secret_key_base }
    ALGORITHM = "HS256"

    ACCESS_TTL = 1.hour
    REFRESH_TTL = 7.days

    def self.encode_access(user_id)
      encode(user_id, type: "access", ttl: ACCESS_TTL)
    end

    def self.encode_refresh(user_id)
      encode(user_id, type: "refresh", ttl: REFRESH_TTL)
    end

    def self.decode(token)
      payload = JWT.decode(token, SECRET, true, algorithm: ALGORITHM).first
      payload.symbolize_keys
    rescue JWT::DecodeError, JWT::ExpiredSignature => e
      raise Auth::AuthError, e.message
    end

    def self.encode(user_id, type:, ttl:)
      payload = {
        sub: user_id,
        type: type,
        exp: ttl.from_now.to_i,
        iat: Time.current.to_i
      }
      JWT.encode(payload, SECRET, ALGORITHM)
    end
  end
end
