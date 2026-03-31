# frozen_string_literal: true

# TASK-032 FR-012: Action Cable connection with JWT auth.
# PG WARNING #3: Connection rate limiting via Redis counter.

module ApplicationCable
  class Connection < ActionCable::Connection::Base
    identified_by :current_user, :extension_install_id

    MAX_CONNECTIONS_PER_IP = 50
    CONNECTION_WINDOW = 60 # seconds

    def connect
      reject_unauthorized_connection if connection_limit_exceeded?

      self.current_user = find_verified_user
      self.extension_install_id = request.params[:extension_install_id]

      reject_unauthorized_connection unless current_user || extension_install_id
    end

    private

    def find_verified_user
      token = request.params[:token]
      return nil unless token

      payload = Auth::JwtService.decode(token)
      return nil unless payload[:type] == "access"

      User.active.find(payload[:sub])
    rescue Auth::AuthError, ActiveRecord::RecordNotFound
      nil
    end

    def connection_limit_exceeded?
      ip = request.remote_ip
      key = "cable:connections:#{ip}"

      count = Rails.cache.increment(key, 1, expires_in: CONNECTION_WINDOW)
      count > MAX_CONNECTIONS_PER_IP
    rescue StandardError
      false
    end
  end
end
