# frozen_string_literal: true

# TASK-039 Visual QA: rake tasks для seeding/clearing synthetic channels на
# staging/development. Invoked перед Visual QA Mode B agent runs.
#
# ВАЖНО: каждый task имеет production guard (Trends::VisualQa::DataSeeder
# refuses Rails.env.production). Staging/development only.
#
# Usage:
#   bin/rails 'trends:visual_qa:seed[vqa_test_01]'                     # default profile
#   bin/rails 'trends:visual_qa:seed[vqa_test_02,streamer_with_rehab]' # named profile
#   bin/rails 'trends:visual_qa:clear[vqa_test_01]'
#   bin/rails 'trends:visual_qa:status[vqa_test_01]'

namespace :trends do
  namespace :visual_qa do
    desc "Seed synthetic channel chain для Visual QA (profile: premium_tracked | streamer_with_rehab | cold_start)"
    task :seed, %i[login profile] => :environment do |_t, args|
      login = args[:login].presence || raise("login required: bin/rails 'trends:visual_qa:seed[vqa_test_01]'")
      profile = args[:profile].presence || "premium_tracked"

      result = Trends::VisualQa::DataSeeder.seed(login: login, profile: profile)
      channel = result[:channel]
      stats = result[:stats]

      puts "=" * 60
      puts "Visual QA seed COMPLETED"
      puts "  channel_id: #{channel.id}"
      puts "  login:      #{login}"
      puts "  profile:    #{profile}"
      puts "  stats:"
      stats.each { |k, v| puts "    #{k}: #{v}" }
      puts "=" * 60
    end

    desc "Teardown synthetic VQA channel data (removes chain + metadata row)"
    task :clear, %i[login] => :environment do |_t, args|
      login = args[:login].presence || raise("login required")
      result = Trends::VisualQa::DataSeeder.clear(login: login)

      if result[:cleared]
        puts "Visual QA clear COMPLETED for '#{login}':"
        result[:stats].each { |k, v| puts "  #{k}: #{v}" }
      else
        puts "Visual QA clear SKIPPED: #{result[:reason]}"
      end
    end

    desc "Inspect VQA seeded channel (live counts + seed metadata)"
    task :status, %i[login] => :environment do |_t, args|
      login = args[:login].presence || raise("login required")
      info = Trends::VisualQa::DataSeeder.new(login: login, profile: nil).status

      puts "Visual QA status for '#{login}':"
      info.each { |k, v| puts "  #{k}: #{v.inspect}" }
    end
  end
end
