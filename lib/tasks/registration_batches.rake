# frozen_string_literal: true

# Sweep the Twitch user-ID space for accounts that were manufactured in batches.
#
# Twitch issues IDs sequentially, so a batch registered in one sitting occupies a contiguous window.
# BotDetection::RegistrationBatch scores a window on the marks its generator left; this task owns
# the fetching, the rate limiting and the reporting.
#
#   rake "bots:sweep[300000000,1545000000,8000000]"   # coarse survey of the whole space
#   rake "bots:sweep[1268000000,1340000000,250000]"   # dense pass over a hot range
#   rake "bots:roster[1238712400,1238712900]"         # dump one window's accounts
#
# Read-only against Twitch; writes nothing. The output is meant to be read, then acted on.
namespace :bots do
  WINDOW = 100      # Helix /users takes 100 ids per call — one call per window
  PAUSE  = 0.12     # ~500 calls/min, comfortably inside the app-token budget

  desc "Score ID windows for batch-manufactured accounts [from,to,step]"
  task :sweep, %i[from to step] => :environment do |_t, args|
    from = Integer(args[:from] || 300_000_000)
    to   = Integer(args[:to]   || 1_545_000_000)
    step = Integer(args[:step] || 8_000_000)

    rows = []
    (from..to).step(step) do |base|
      users = Bots.fetch_window(base)
      next if users.size < BotDetection::RegistrationBatch::MIN_SAMPLE

      rows << [ base, users.first["created_at"].to_s[0, 10], BotDetection::RegistrationBatch.score(users) ]
      sleep PAUSE
    end

    if rows.empty?
      puts "Ни одного окна с достаточной выборкой в #{from}..#{to}"
      next
    end

    puts format("Просканировано окон: %d (шаг %d)", rows.size, step)
    # Only the bio columns score; каша/аватарки/корни are diagnostics that a 2023 control proved to
    # be background (see BotDetection::RegistrationBatch#score).
    puts format("%-13s %-11s %-5s %-6s %-6s %-7s %-6s  %s",
                "ID", "создан", "n", "score", "дубль", "шабл/з", "заполн", "маркеры")
    rows.sort_by { |(_, _, r)| -r.score }.first(25).each do |base, day, r|
      puts format("%-13d %-11s %-5d %-6.2f %-6.2f %-7.2f %-6d  %s",
                  base, day, r.accounts, r.score, r.duplicate_bio_share,
                  r.template_among_carriers, r.bio_carriers, r.markers.join(","))
    end

    scores = rows.map { |(_, _, r)| r.score }.sort
    puts format("\nФон: медиана score %.2f, 90-й перцентиль %.2f, максимум %.2f",
                scores[scores.size / 2], scores[(scores.size * 0.9).to_i], scores.last)
    puts format("Окон с маркером: %d из %d", rows.count { |(_, _, r)| r.markers.any? }, rows.size)
  end

  desc "Dump the accounts of one ID window [from,to]"
  task :roster, %i[from to] => :environment do |_t, args|
    from = Integer(args[:from])
    to   = Integer(args[:to])

    users = (from...to).step(WINDOW).flat_map { |b| u = Bots.fetch_window(b); sleep PAUSE; u }
    r = BotDetection::RegistrationBatch.score(users)
    puts format("Аккаунтов: %d, дней создания: %d, score %.2f, маркеры: %s",
                users.size, r.created_days, r.score, r.markers.join(","))
    users.sort_by { |u| u["id"].to_i }.each do |u|
      puts format("%-12s %-28s %s", u["id"], u["login"], u["description"].to_s[0, 50])
    end
  end

  # Helix fetch, isolated so both tasks share one implementation and one failure policy: a window
  # that errors is skipped rather than aborting a sweep that may be thousands of calls long.
  module Bots
    module_function

    def fetch_window(base)
      client = (@client ||= Twitch::HelixClient.new)
      ids = (base...(base + WINDOW)).to_a
      uri = URI("https://api.twitch.tv/helix/users?" + ids.map { |i| "id=#{i}" }.join("&"))
      req = Net::HTTP::Get.new(uri)
      req["Client-Id"] = ENV.fetch("TWITCH_CLIENT_ID")
      req["Authorization"] = "Bearer #{client.app_token}"
      res = Net::HTTP.start(uri.host, uri.port, use_ssl: true, read_timeout: 20) { |h| h.request(req) }
      JSON.parse(res.body)["data"] || []
    rescue StandardError => e
      Rails.logger.warn("bots:sweep window #{base} failed (#{e.class}: #{e.message})")
      []
    end
  end
end
