# frozen_string_literal: true

# TASK-113 BE-2: Personal Viewer Analytics authorization. Ownership-only — пользователь видит ТОЛЬКО
# свою аналитику (контроллер всегда scoped к current_user). PVA all-free → НЕТ paywall-гейтов
# (нет SUBSCRIPTION_REQUIRED). record = current_user.
class PersonalAnalyticsPolicy < ApplicationPolicy
  def overview?
    own_analytics?
  end

  private

  # record (current_user) == authenticated user → свои данные.
  def own_analytics?
    registered? && record == user
  end
end
