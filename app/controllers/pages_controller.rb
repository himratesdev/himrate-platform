# frozen_string_literal: true

# Public marketing landing (TASK-060). Server-rendered HTML on a dedicated
# `landing` layout. No auth — these are public GET pages. API / extension
# traffic (api/v1/*) is unaffected: this only adds top-level html routes.
class PagesController < ApplicationController
  layout "landing"

  # Phase 0 = root smoke only. streamers / brands / viewers / methodology + legal
  # actions are added with their views in the literal-port phases.
  def index; end
end
