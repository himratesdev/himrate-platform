# frozen_string_literal: true

module BotDetection
  # Scores a window of Twitch account IDs for having been MANUFACTURED IN A BATCH.
  #
  # WHY THIS AND NOT BEHAVIOUR (2026-09-13):
  #   Every behavioural route to a view-botting fleet is closed. Chat co-occurrence finds nothing at
  #   any scale — measured across 178,661 channels, everything above ten channels an hour is a named
  #   utility bot. The reason is structural: inflating a viewer count needs no messages, and a
  #   message is the thing that would give you away. We then enumerated 114 accounts that ARE
  #   manufactured (identical bio, generated logins, one registration window) and found zero
  #   messages from them in 148M rows and zero appearances in 4.9M viewer snapshots. They are
  #   invisible to everything we can observe about behaviour.
  #
  #   What they cannot hide is how they were made. Twitch IDs are issued sequentially, so a batch
  #   registered in one sitting occupies a contiguous ID window, and the accounts in it carry the
  #   marks of their generator.
  #
  # WHY FUZZY AND NOT EXACT:
  #   The manufacturers adapt, and we can watch them do it across three generations:
  #     May 2025    — 57 of 72 accounts share the bio "look at me now ))))))))))" verbatim.
  #     July 2025   — all 99 bios empty, all 99 avatars default, logins uniformly 10 random chars.
  #     January 2026— bios drawn from a template pool with a random two-letter suffix glued on
  #                   ("Stream ohne Erwartungen om", "Zocken ohne Druck il"), logins deliberately
  #                   mixed between gibberish and human-looking.
  #   Exact-duplicate matching caught the first generation and misses the third. What the third
  #   still cannot avoid: the batch is created in one day, most avatars stay default, and the login
  #   generator leaves shared stems ("deadzoneinputgg4549" / "rawinputgg1870").
  #
  # BASELINE (142 windows sampled across 2020→2026): median duplicate-bio share 1.1%, median
  # gibberish-login share 14.8%. Factory windows measured 30–79% on the first and up to 68% on the
  # second, so the separation is wide — this does not need a delicate threshold.
  #
  # Pure function over already-fetched user hashes (Helix /users shape). No network here: the caller
  # owns fetching and rate limits, which keeps this unit-testable and keeps one probe reusable by
  # several scorers.
  class RegistrationBatch
    # A bio is "templated" when two accounts' bios differ only by a short tail. The January 2026
    # generator glues 2 random letters on; allowing a quarter of the string keeps that in range
    # without collapsing genuinely different sentences together.
    TEMPLATE_DISTANCE_RATIO = 0.25
    # Below this a "shared stem" is meaningless — "the", "gg" and friends collide by chance.
    MIN_STEM_LENGTH = 6
    # Vowel share outside this band reads as generated rather than typed by a person.
    VOWEL_BAND = (0.28..0.62)

    Result = Data.define(
      :accounts, :created_days, :dominant_day_share,
      :duplicate_bio_share, :template_bio_share, :gibberish_share,
      :default_avatar_share, :shared_stem_share, :score, :markers
    )

    # users — Array of Helix /users hashes: login, description, profile_image_url, created_at.
    def self.score(users)
      users = Array(users).compact
      return empty_result if users.size < MIN_SAMPLE

      new(users).result
    end

    MIN_SAMPLE = 10

    def self.empty_result
      Result.new(accounts: 0, created_days: 0, dominant_day_share: 0.0, duplicate_bio_share: 0.0,
                 template_bio_share: 0.0, gibberish_share: 0.0, default_avatar_share: 0.0,
                 shared_stem_share: 0.0, score: 0.0, markers: [])
    end
    private_class_method :empty_result

    def initialize(users)
      @users = users
      @logins = users.map { |u| u["login"].to_s.downcase }
      @bios = users.map { |u| u["description"].to_s.strip }
    end

    def result
      markers = []
      markers << "duplicate-bio"  if duplicate_bio_share >= 0.20
      markers << "template-bio"   if template_bio_share >= 0.30
      markers << "gibberish-login" if gibberish_share >= 0.40
      markers << "default-avatar" if default_avatar_share >= 0.80
      markers << "shared-stem"    if shared_stem_share >= 0.20
      markers << "single-day"     if dominant_day_share >= 0.90

      Result.new(
        accounts: @users.size, created_days: created_days,
        dominant_day_share: r(dominant_day_share), duplicate_bio_share: r(duplicate_bio_share),
        template_bio_share: r(template_bio_share), gibberish_share: r(gibberish_share),
        default_avatar_share: r(default_avatar_share), shared_stem_share: r(shared_stem_share),
        score: r(score), markers: markers
      )
    end

    private

    def r(v) = v.to_f.round(3)

    # Weighted so that no SINGLE marker convicts a window. Same-day creation is worth little on its
    # own — a 100-ID window is minutes of Twitch registrations, so it is nearly always one day; it
    # earns its weight only alongside a generator mark. Duplicate and templated bios are the same
    # tell one generation apart, so they share a weight rather than stacking.
    def score
      bio = [ duplicate_bio_share, template_bio_share ].max
      (0.35 * bio) + (0.25 * gibberish_share) + (0.20 * shared_stem_share) +
        (0.12 * default_avatar_share) + (0.08 * dominant_day_share)
    end

    def created_days = @users.map { |u| u["created_at"].to_s[0, 10] }.uniq.size

    def dominant_day_share
      days = @users.map { |u| u["created_at"].to_s[0, 10] }.tally
      return 0.0 if days.empty?

      days.values.max.to_f / @users.size
    end

    # Generation 1: the same string, character for character.
    def duplicate_bio_share
      filled = @bios.reject(&:empty?)
      return 0.0 if filled.empty?

      filled.tally.values.max.to_f / @users.size
    end

    # Generation 3: bios that are the same sentence with a different tail. Clusters greedily —
    # exact clustering is quadratic and pointless at these sample sizes, and the biggest cluster is
    # all we report.
    def template_bio_share
      filled = @bios.reject(&:empty?).uniq
      return 0.0 if filled.size < 2

      best = filled.map { |seed| filled.count { |other| templated?(seed, other) } }.max
      # Scale by how many accounts carry a bio at all, then express over the whole window.
      carriers = @bios.count { |b| !b.empty? }
      return 0.0 if carriers.zero?

      (best.to_f / filled.size) * (carriers.to_f / @users.size)
    end

    def templated?(a, b)
      longer = [ a.length, b.length ].max
      return false if longer < 8

      levenshtein(a, b) <= (longer * TEMPLATE_DISTANCE_RATIO).ceil
    end

    # Generation 2: logins straight out of a random generator. Human logins sit in a normal vowel
    # band; generated ones cluster at the extremes (no vowels, or alternating filler).
    def gibberish_share
      @logins.count { |l| gibberish?(l) }.to_f / @users.size
    end

    def gibberish?(login)
      letters = login.gsub(/[^a-z]/, "")
      return false if letters.length < 6

      !VOWEL_BAND.cover?(letters.count("aeiou").to_f / letters.length)
    end

    # Generation 3 leaves this even when it randomises everything else: one generator seeded several
    # logins from the same stem. Counts accounts whose login shares a ≥6-char substring with another
    # login in the window — cheap because we only test the stems that actually repeat.
    def shared_stem_share
      stems = Hash.new { |h, k| h[k] = Set.new }
      @logins.each_with_index do |login, i|
        letters = login.gsub(/[^a-z]/, "")
        next if letters.length < MIN_STEM_LENGTH

        (0..(letters.length - MIN_STEM_LENGTH)).each do |off|
          stems[letters[off, MIN_STEM_LENGTH]] << i
        end
      end
      shared = stems.values.select { |idx| idx.size > 1 }.reduce(Set.new, :|)
      shared.size.to_f / @users.size
    end

    def default_avatar_share
      @users.count { |u| u["profile_image_url"].to_s.include?("user-default") }.to_f / @users.size
    end

    def levenshtein(a, b)
      return b.length if a.empty?
      return a.length if b.empty?

      prev = (0..b.length).to_a
      a.each_char.with_index do |ca, i|
        row = [ i + 1 ]
        b.each_char.with_index do |cb, j|
          row << [ prev[j + 1] + 1, row[j] + 1, prev[j] + (ca == cb ? 0 : 1) ].min
        end
        prev = row
      end
      prev.last
    end
  end
end
