# frozen_string_literal: true

# Screen 04 «Куда пойти» — live-now discovery. Viewer-free (any registered user, access-model v2):
# the dashboard viewer surface carries no paywall; ranking data is the same public headline metric.
class DiscoverPolicy < ApplicationPolicy
  def live?
    registered? && record == user
  end
end
