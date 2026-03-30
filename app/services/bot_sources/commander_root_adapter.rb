# frozen_string_literal: true

# TASK-026: CommanderRoot known bot list adapter.
# Largest public bot database (11.8M+).
# Bulk download endpoint: TBD — needs research (SRS §14).
# Until endpoint is found, returns empty (honest stub, not fake data).

module BotSources
  class CommanderRootAdapter < BaseAdapter
    def fetch
      # CommanderRoot bulk API endpoint not yet researched.
      # SRS §14 open question: "CommanderRoot bulk download endpoint — нужно исследовать при Dev"
      # Returning empty until real endpoint is implemented.
      # DO NOT use TwitchInsights API and label it as CommanderRoot — that inflates cross-reference.
      Rails.logger.info("CommanderRootAdapter: bulk endpoint TBD, returning empty")
      []
    end

    def source_name
      "commanderroot"
    end

    def bot_category
      "view_bot"
    end
  end
end
