# frozen_string_literal: true

# FR-003: Health endpoint GET /health → 200 OK
# Checks PostgreSQL and Redis connectivity
class HealthController < ApplicationController
  def show
    checks = {
      db: check_database,
      redis: check_redis
    }

    status = checks.values.all? ? :ok : :service_unavailable

    render json: { status: status == :ok ? "ok" : "error", **checks }, status: status
  end

  private

  def check_database
    ActiveRecord::Base.connection.active?
  rescue StandardError
    false
  end

  def check_redis
    redis = Redis.new(url: ENV.fetch("REDIS_URL", "redis://localhost:6379/0"))
    redis.ping == "PONG"
  rescue StandardError
    false
  ensure
    redis&.close
  end
end
