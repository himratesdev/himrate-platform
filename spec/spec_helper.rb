# frozen_string_literal: true

RSpec.configure do |config|
  config.expect_with :rspec do |expectations|
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
  end

  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end

  config.shared_context_metadata_behavior = :apply_to_host_groups
  config.filter_run_when_matching :focus

  # 4.3 external-integration lane (ai-dev-team/CLAUDE.md: «для КАЖДОГО внешнего сервиса —
  # реальный integration-спек»). Specs tagged `external: true` hit real third-party services
  # (Twitch Helix/GQL/IRC, whisper) and are excluded from the default sweep; opt in with
  # EXTERNAL_INTEGRATION=1 (CI: .github/workflows/integration-external.yml, nightly).
  config.filter_run_excluding external: true unless ENV["EXTERNAL_INTEGRATION"] == "1"
  config.order = :random
  Kernel.srand config.seed
end
