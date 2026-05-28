# frozen_string_literal: true

# TASK-113 BE-2: Personal Viewer Analytics authorization. Ownership-only — пользователь видит ТОЛЬКО
# свою аналитику (контроллер всегда scoped к current_user). PVA all-free → НЕТ paywall-гейтов
# (нет SUBSCRIPTION_REQUIRED). record = current_user.
class PersonalAnalyticsPolicy < ApplicationPolicy
  def overview?
    own_analytics?
  end

  # Client-capture ingest своих данных (M7 events + M6 chat).
  def ingest?
    own_analytics?
  end

  # BE-5 (CR nit-1): action-specific policy methods — семантически чётче чем generic :overview?
  # для PUT/DELETE/POST. Логика идентична own_analytics? (PVA all-free, ownership-only — нет paywall),
  # но раздельные методы дают spec'ам гранулярную проверку + читаемость в audit-логах.
  def update_privacy?
    own_analytics?
  end

  def delete_account?
    own_analytics?
  end

  def export?
    own_analytics?
  end

  def download_export?
    own_analytics?
  end

  private

  # record (current_user) == authenticated user → свои данные.
  def own_analytics?
    registered? && record == user
  end
end
