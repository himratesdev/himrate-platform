# frozen_string_literal: true

require "rails_helper"

# T1-064 FR-6 (ADR DEC-5): enforcement guard. Health Score was removed in philosophy v2
# (TASK-201) but orphaned references survived in app/ (channels_controller card field +
# signal_compute_worker cache-delete). This spec fails if any `health_score` reference
# reappears in app/, making T1-064 the LAST Health Score cleanup.
#
# Note: db/migrate/ legitimately contains health_score in TASK-201 down-methods (reversibility)
# and is intentionally NOT covered here.
RSpec.describe "No Health Score references in app/", type: :architecture do
  # Empty allowlist — Health Score is fully removed. Add a path here only with an explicit
  # reason if a legitimate future use ever needs the token (none expected).
  ALLOWLIST = [].freeze

  it "has zero health_score references in app/" do
    root = Rails.root.join("app")
    offenders = Dir.glob(root.join("**", "*.rb")).select do |path|
      next false if ALLOWLIST.any? { |allowed| path.end_with?(allowed) }

      File.read(path).match?(/health_score/i)
    end.map { |p| Pathname.new(p).relative_path_from(Rails.root).to_s }

    expect(offenders).to eq([]),
      "Health Score is removed (philosophy v2). Orphaned references found: #{offenders.join(', ')}"
  end
end
