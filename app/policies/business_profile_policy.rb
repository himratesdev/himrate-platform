# frozen_string_literal: true

# ONBOARD-D0 (screen 72): any registered user may view/edit/submit their OWN business
# application (the controller always scopes to current_user.business_profile — there is
# no cross-user record access to gate). Approve/reject are not API actions (PO runner).
class BusinessProfilePolicy < ApplicationPolicy
  def show?
    registered?
  end

  def update?
    registered?
  end

  def submit?
    registered?
  end
end
