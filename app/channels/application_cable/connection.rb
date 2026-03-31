# frozen_string_literal: true

# TASK-032 FR-012: Action Cable connection with JWT auth.
# Extension connects via WebSocket with JWT token.
# Guest connections allowed with extension_install_id (for analytics).

module ApplicationCable
  class Connection < ActionCable::Connection::Base
    identified_by :current_user, :extension_install_id

    def connect
      self.current_user = find_verified_user
      self.extension_install_id = request.params[:extension_install_id]

      # At least one identifier must be present
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
  end
end
