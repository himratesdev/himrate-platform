# frozen_string_literal: true

# Coordination findings are facts about a channel, and facts about a channel are free (brief §7:
# "замков на фактах о канале нет" — the paid boundary is sets, period depth and exports).
# Headless record (:coordination symbol).
class CoordinationPolicy < ApplicationPolicy
  def show?
    true
  end
end
