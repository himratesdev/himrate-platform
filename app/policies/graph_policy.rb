# frozen_string_literal: true

# W5: the audience graph.
#
# WEB-CONSOLIDATION §11.3 (PO 2026-09-09): open, guests included. Who a channel shares its audience
# with is a fact about that channel, and the neighbours block on the public card is built from this
# same ego payload — one cache entry serves the card and /graph?focus= alike. The paid boundary is
# working with SETS of channels (/plan: comparison, combined reach, picking), not looking at one.
# Headless record (:graph symbol).
class GraphPolicy < ApplicationPolicy
  def audience?
    true
  end
end
