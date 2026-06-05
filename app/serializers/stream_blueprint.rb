# frozen_string_literal: true

# TASK-031: Stream serializer.

class StreamBlueprint < Blueprinter::Base
  identifier :id

  view :basic do
    fields :started_at, :ended_at

    # PR-A1 (EPIC SCALE ARCHITECTURE Step 2): peak_ccv / avg_ccv / duration_ms columns
    # dropped from streams. Derived via Stream#current_* methods — single source of truth
    # is CcvSnapshot (live) and PostStreamReport (ended).
    field :peak_ccv do |stream, _options|
      stream.current_peak_ccv
    end

    field :avg_ccv do |stream, _options|
      stream.current_avg_ccv
    end

    field :duration_ms do |stream, _options|
      stream.current_duration_ms
    end

    field :game_name do |stream, _options|
      stream.game_name
    end

    field :title do |stream, _options|
      stream.title
    end
  end
end
