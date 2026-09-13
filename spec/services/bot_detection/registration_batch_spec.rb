# frozen_string_literal: true

require "rails_helper"

# The fixtures below are shapes taken from live Twitch data on 2026-09-13, not invented: three
# generations of the same factory, and a control window of ordinary accounts. The point of the
# scorer is that it must survive the generation that defeated exact matching, so the January 2026
# sample is the one that matters.
RSpec.describe BotDetection::RegistrationBatch do
  def user(login, bio: "", avatar: "https://static-cdn.jtvnw.net/jtv_user_pictures/abc.png",
           day: "2025-05-08")
    { "login" => login, "description" => bio, "profile_image_url" => avatar,
      "created_at" => "#{day}T10:00:00Z" }
  end

  def default_avatar = "https://static-cdn.jtvnw.net/user-default-pictures-uv/1.png"

  # Generation 1 (ID window 1308000000): 57 of 72 carried this bio verbatim.
  let(:gen1) do
    %w[rpoonnyc15 bigsherm2074 micaelasotook81 btc_geobey52 jeanfra4273019186
       nicoldiscua67 kotik_milka34 dareeen_ lin249958 emerald_66744 marcus_r12 sofiadelgado8]
      .map { |l| user(l, bio: "look at me now ))))))))))") }
  end

  # Generation 2 (1332000000): nothing filled in at all, logins uniformly ten random characters.
  let(:gen2) do
    %w[a7hia6gqei nlkmmsh2fa sg8mzsolsj zrwfrsdgr1 8xvu2lfodz hqwdhkuxwk
       mx00nbgya5 sckpnzb7ln c0o1r9r6gr n5kdabi4kb w3rtbnmqkz pl9xcvbnms]
      .map { |l| user(l, avatar: default_avatar, day: "2025-07-10") }
  end

  # Generation 3 (1428000000): bios from a template pool with a random two-letter tail glued on,
  # logins deliberately mixed. This is the one that beats duplicate matching.
  let(:gen3) do
    [
      user("jea9bmp77g3r", bio: "Stream ohne Erwartungen om", avatar: default_avatar, day: "2026-01-19"),
      user("riy77trsw1nv", bio: "Stream ist Hobby, nicht Beruf vm", avatar: default_avatar, day: "2026-01-19"),
      user("deadzoneinputgg4549", bio: "Zocken ohne Druck il", avatar: default_avatar, day: "2026-01-19"),
      user("nanno_assassin", bio: "Gaming ohne Plan jb", avatar: default_avatar, day: "2026-01-19"),
      user("wuqufdmha2ko", bio: "Stream ohne Erwartungen qz", avatar: default_avatar, day: "2026-01-19"),
      user("hectorheck39", bio: "Zocken ohne Druck ka", avatar: default_avatar, day: "2026-01-19"),
      user("rawinputgg1870", bio: "Gaming ohne Plan xt", avatar: default_avatar, day: "2026-01-19"),
      user("epd29o3jkcbr", bio: "Stream ist Hobby, nicht Beruf pw", avatar: default_avatar, day: "2026-01-19"),
      user("vataidani", bio: "", avatar: default_avatar, day: "2026-01-19"),
      user("snwvobl0x88t", bio: "", avatar: default_avatar, day: "2026-01-19"),
      user("inputgg99231", bio: "Zocken ohne Druck bn", avatar: default_avatar, day: "2026-01-19"),
      user("mirkoshhh", bio: "", avatar: default_avatar, day: "2026-01-19")
    ]
  end

  # Control: real people. Same-day creation is normal in a 100-ID window — Twitch issues IDs
  # sequentially, so the day alone must never carry a verdict.
  let(:humans) do
    [
      user("alexobscure", bio: "just here to game and laugh"),
      user("shimapanknight", bio: "Xbox streamer small account"),
      user("kotik_milka", bio: ""),
      user("danya_sunset", bio: "привет всем, играю в доту"),
      user("veltoox_99", bio: ""),
      user("mistafaker", bio: "twitch partner, business: mail@example.com"),
      user("recrent", bio: ""),
      user("baton1503", bio: "Sejam Bem Vidos Obrigado Por Assistir"),
      user("legoika", bio: ""),
      user("nar7_ttv", bio: "gamer"),
      user("prettyboycoldin", bio: ""),
      user("aseke_d333", bio: "salam")
    ]
  end

  describe "the three generations" do
    it "scores generation 1 on its verbatim duplicate bio" do
      r = described_class.score(gen1)

      expect(r.duplicate_bio_share).to be > 0.9
      expect(r.markers).to include("duplicate-bio")
    end

    # Generation 2 is HONESTLY INVISIBLE to this scorer and the spec says so. It fills nothing, and
    # the marks it does leave — random logins, default avatars — are what ordinary Twitch windows
    # look like too: a 2023 control range measured 0.30–0.67 gibberish and near-universal default
    # avatars, higher than several known factory windows. Pretending otherwise is how the first
    # version of this class ended up ranking the control ABOVE the factories.
    it "does not pretend to see generation 2, which fills nothing" do
      r = described_class.score(gen2)

      expect(r.duplicate_bio_share).to eq(0.0)
      expect(r.markers).to be_empty
      # The diagnostics still describe it once something else has found it.
      expect(r.gibberish_share).to be > 0.5
      expect(r.default_avatar_share).to eq(1.0)
    end

    it "catches generation 3 by measuring templates among the accounts that filled a bio" do
      r = described_class.score(gen3)

      expect(r.duplicate_bio_share).to be < 0.2   # the random tail did its job
      expect(r.template_among_carriers).to be > 0.9 # …but among carriers the pool is obvious
      expect(r.markers).to include("template-bio")
    end

    # The trap this guards: on a live window (1428000000) five of seventy-nine accounts carried a
    # bio and four were one template pool. Measured as a share of the WINDOW that is 0.05 — below
    # any sane threshold — which is exactly why the first version scored the whole of 2026 at
    # 0.00–0.03 and saw nothing.
    it "sees a template pool that only a handful of accounts carry" do
      # Two template pairs — "Stream ohne Erwartungen om/qz" and "Zocken ohne Druck il/ka" — buried
      # among forty accounts that filled nothing, which is the live proportion.
      pairs = gen3.values_at(0, 4, 2, 5)
      sparse = pairs + Array.new(40) { |i| user("filler#{i}", avatar: default_avatar, day: "2026-01-19") }
      r = described_class.score(sparse)

      expect(r.template_bio_share).to be < 0.15     # invisible as a share of the window
      expect(r.template_among_carriers).to be > 0.9 # visible among carriers
      expect(r.markers).to include("template-bio")
    end

    it "ranks the detectable generations above ordinary accounts" do
      human_score = described_class.score(humans).score

      [ gen1, gen3 ].each do |batch|
        expect(described_class.score(batch).score).to be > human_score * 2
      end
    end
  end

  describe "the control" do
    it "does not flag a window of real people" do
      r = described_class.score(humans)

      expect(r.markers).to be_empty
      expect(r.score).to be < 0.25
    end

    # The regression a 2023 control range actually produced against the first version of this
    # class: random logins and default avatars are the BACKGROUND of ordinary Twitch registrations
    # (0.30–0.67 gibberish, near-universal defaults), so a window full of them must not outscore a
    # real factory. This assertion is what keeps them out of the vote.
    it "does not score a window of blank, randomly-named accounts above a real factory" do
      blank = Array.new(30) { |i| user("q#{i}x8zvbn#{i}", avatar: default_avatar, day: "2023-09-02") }

      expect(described_class.score(blank).score).to be < described_class.score(gen1).score
      expect(described_class.score(blank).markers).to be_empty
    end

    # A 100-ID window spans minutes of Twitch registrations, so one creation day is the norm, not
    # evidence. If this ever convicts on its own the weighting has drifted.
    it "does not convict on same-day creation alone" do
      same_day = humans.map { |u| u.merge("created_at" => "2025-05-08T10:00:00Z") }
      r = described_class.score(same_day)

      expect(r.dominant_day_share).to eq(1.0)
      expect(r.score).to be < 0.25
    end
  end

  describe "guards" do
    it "returns a zeroed result rather than noise on a sample too small to mean anything" do
      r = described_class.score(gen1.first(4))

      expect(r.accounts).to eq(0)
      expect(r.score).to eq(0.0)
      expect(r.markers).to be_empty
    end

    it "tolerates nils and missing fields" do
      expect { described_class.score([ nil, {}, *gen1 ]) }.not_to raise_error
    end

    it "counts distinct creation days" do
      mixed = gen1.first(6) + gen2.first(6)
      expect(described_class.score(mixed).created_days).to eq(2)
    end
  end
end
