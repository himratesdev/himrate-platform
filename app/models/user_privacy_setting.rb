# frozen_string_literal: true

# TASK-113 (FR-014, M15): privacy/visibility toggles + consent-log (GDPR).
# Defaults (DB): все ON кроме display_name_visible (OFF — псевдоним по умолчанию). PO decision.
class UserPrivacySetting < ApplicationRecord
  belongs_to :user

  validates :user_id, presence: true, uniqueness: true

  scope :for_user, ->(user) { where(user_id: user.id) }

  # GDPR: псевдоним, который видит стример пока display_name_visible = false.
  def streamer_facing_alias
    "User_#{Digest::SHA256.hexdigest(user_id.to_s)[0, 4]}"
  end
end
