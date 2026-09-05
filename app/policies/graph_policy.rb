# frozen_string_literal: true

# W5: the audience graph is registered-open for launch (the PO needs the full picture live);
# the intended monetized gate is business-tier — flip `registered?` to `effective_business?`
# when billing ships. Headless record (:graph symbol).
class GraphPolicy < ApplicationPolicy
  def audience?
    registered?
  end
end
