# frozen_string_literal: true

module Auth
  class JwtService
    # BUG-251.16: never run auth with a blank HMAC signing key (defense-in-depth for the empty-key
    # condition CVE-2026-45363 abuses; jwt 2.10.3 also blocks it gem-level). A bare
    # ENV.fetch("JWT_SECRET") { fallback } only falls back when JWT_SECRET is ABSENT — an explicit
    # JWT_SECRET="" would slip through as "". resolve_secret treats empty same as absent (→ fallback)
    # and raises only when NO usable secret exists, so boot fails loud rather than signing with "".
    def self.resolve_secret(env_value, fallback)
      (env_value.presence || fallback).presence ||
        raise("JWT signing secret is blank — set JWT_SECRET or Rails secret_key_base")
    end

    SECRET = resolve_secret(ENV["JWT_SECRET"], Rails.application.secret_key_base)
    ALGORITHM = "HS256"

    ACCESS_TTL = 1.hour
    REFRESH_TTL = 7.days

    # T1-060 FR-5: surface the token is minted for (extension vs dashboard), stamped as the
    # JWT `aud` claim. Keyword defaults to EXTENSION so every existing call-site keeps
    # minting extension tokens unchanged; the dashboard surface arrives with the SaaS ЛК (T3).
    DEFAULT_SURFACE = Auth::AuthContext::EXTENSION

    def self.encode_access(user_id, surface: DEFAULT_SURFACE)
      encode(user_id, type: "access", ttl: ACCESS_TTL, surface: surface)
    end

    def self.encode_refresh(user_id, surface: DEFAULT_SURFACE)
      encode(user_id, type: "refresh", ttl: REFRESH_TTL, surface: surface)
    end

    def self.decode(token)
      payload = JWT.decode(token, SECRET, true, algorithm: ALGORITHM).first
      payload.symbolize_keys
    rescue JWT::DecodeError, JWT::ExpiredSignature => e
      raise Auth::AuthError, e.message
    end

    # `aud` is a read-only surface signal — decode does NOT enforce it (no verify_aud), so an
    # old token without `aud` is still valid and resolves to EXTENSION downstream (BR-8).
    def self.encode(user_id, type:, ttl:, surface: DEFAULT_SURFACE)
      payload = {
        sub: user_id,
        type: type,
        aud: surface,
        exp: ttl.from_now.to_i,
        iat: Time.current.to_i
      }
      JWT.encode(payload, SECRET, ALGORITHM)
    end
  end
end
