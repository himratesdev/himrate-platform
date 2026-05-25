# frozen_string_literal: true

module Channels
  # TASK-251.12 (hybrid monitoring set): seed + pin the curated RU-streamer list.
  #
  # Reads db/seeds/curated_channels.yml, resolves each login to a twitch_id via Helix /users, and
  # upserts the Channel as monitored + pinned. Pinned channels are guaranteed-monitored and protected
  # from the discovery-cleanup prune (TASK-251.2). Idempotent — re-running re-pins existing rows and
  # tops up newly-added logins. Logins Helix can't resolve (banned/renamed/typo) are logged + skipped;
  # a transient Helix failure skips that batch (no raise) so a re-run completes it.
  class CuratedSeeder
    SEED_PATH = Rails.root.join("db/seeds/curated_channels.yml")
    HELIX_BATCH_SIZE = 100 # Helix /users accepts up to 100 logins per request
    # Twitch login charset. A malformed entry (invalid chars / >25) is the only thing that makes
    # /users?login= return 400 "Bad Identifiers" and poison the whole batch — a real risk for a
    # hand-edited YAML — so we drop those up front (a format-valid but non-existent login just
    # comes back empty, not 400). Min length 1 keeps legacy short names (e.g. "nix").
    VALID_LOGIN = /\A[a-z0-9_]{1,25}\z/

    Result = Struct.new(:pinned, :unresolved, keyword_init: true)

    def self.call(**) = new(**).call

    def self.load_seed
      YAML.safe_load_file(SEED_PATH) || []
    end

    def initialize(logins: nil, helix: Twitch::HelixClient.new)
      @helix = helix
      @pinned = 0
      @unresolved = []
      @logins = normalize(logins || self.class.load_seed)
    end

    def call
      @logins.each_slice(HELIX_BATCH_SIZE) { |batch| sync_batch(batch) }
      Rails.logger.info("CuratedSeeder: pinned #{@pinned}/#{@logins.size}; unresolved=#{@unresolved.size} #{@unresolved.inspect}")
      Result.new(pinned: @pinned, unresolved: @unresolved)
    end

    private

    def normalize(logins)
      candidates = Array(logins).map { |l| l.to_s.strip.downcase }.reject(&:blank?).uniq
      valid, invalid = candidates.partition { |l| l.match?(VALID_LOGIN) }
      if invalid.any?
        @unresolved.concat(invalid)
        Rails.logger.warn("CuratedSeeder: #{invalid.size} malformed login(s) skipped: #{invalid.inspect}")
      end
      valid
    end

    def sync_batch(batch)
      users = @helix.get_users(logins: batch)
      # nil = transient Helix failure → skip this batch, a re-run picks it up (idempotent).
      return Rails.logger.warn("CuratedSeeder: Helix failed for #{batch.size} logins (retry next run)") if users.nil?

      by_login = users.index_by { |u| u["login"]&.downcase }
      batch.each { |login| upsert(login, by_login[login]) }
    end

    def upsert(login, user)
      return @unresolved << login if user.nil?

      pin_channel(user)
      @pinned += 1
    end

    def pin_channel(user)
      channel = Channel.find_or_initialize_by(twitch_id: user["id"])
      channel.login = user["login"].presence&.downcase || channel.login
      channel.is_monitored = true
      channel.is_pinned = true
      channel.assign_helix_metadata(user) # shared Helix-user → metadata mapping (TASK-251.3/251.12)
      channel.save!
    end
  end
end
