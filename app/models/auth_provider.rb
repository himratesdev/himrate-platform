# frozen_string_literal: true

class AuthProvider < ApplicationRecord
  belongs_to :user

  encrypts :access_token, deterministic: false
  encrypts :refresh_token, deterministic: false
end
