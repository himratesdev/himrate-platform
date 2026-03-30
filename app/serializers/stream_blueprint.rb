# frozen_string_literal: true

# TASK-031: Stream serializer.

class StreamBlueprint < Blueprinter::Base
  identifier :id

  view :basic do
    fields :started_at, :ended_at, :peak_ccv, :avg_ccv, :duration_ms

    field :game_name do |stream, _options|
      stream.game_name
    end

    field :title do |stream, _options|
      stream.title
    end
  end
end
