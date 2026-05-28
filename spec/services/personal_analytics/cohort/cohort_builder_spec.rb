# frozen_string_literal: true

require "rails_helper"

RSpec.describe PersonalAnalytics::Cohort::CohortBuilder do
  let(:user) { create(:user, username: "viewer1") }

  before do
    create(:auth_provider, user: user, provider: "twitch", provider_id: "999")
  end

  # Helpers
  def channel(login)
    create(:channel, login: login, display_name: login.capitalize, twitch_id: SecureRandom.hex(4))
  end

  def watching(username, ch)
    create(:cross_channel_presence, username: username, channel: ch, first_seen_at: 1.day.ago,
      last_seen_at: 1.hour.ago, message_count: 10)
  end

  it "is a no-op for users without Twitch OAuth (Google-only)" do
    other = create(:user, username: "google-only") # no auth_provider
    expect { described_class.call(other.id) }.not_to change(PvaCohort, :count)
  end

  it "is a no-op when the user appears in fewer than MIN_USER_CHANNELS channels" do
    ch_a = channel("xqc")
    watching("viewer1", ch_a) # only 1 channel
    expect { described_class.call(user.id) }.not_to change(PvaCohort, :count)
  end

  it "is a no-op when peers < MIN_PEER_COUNT (edge #7 — «когорта появится позже»)" do
    a = channel("xqc"); b = channel("shroud")
    watching("viewer1", a); watching("viewer1", b)
    # только 4 peer'а (нужно ≥5)
    %w[p1 p2 p3 p4].each { |u| watching(u, a); watching(u, b) }

    expect { described_class.call(user.id) }.not_to change(PvaCohort, :count)
  end

  it "emits suggestions ranked by peer overlap pct (DESC), excluding user's own channels" do
    a, b, c = channel("xqc"), channel("shroud"), channel("hasanabi")
    suggest_strong = channel("summit1g")  # 4 of 5 peers → 80%
    suggest_mid = channel("ludwig")       # 3 of 5 peers → 60%
    suggest_weak = channel("mizkif")      # 1 of 5 peers → 20%

    watching("viewer1", a); watching("viewer1", b)
    %w[p1 p2 p3 p4 p5].each do |peer|
      watching(peer, a); watching(peer, b) # peers разделяют каналы с user
    end
    %w[p1 p2 p3 p4].each { |peer| watching(peer, suggest_strong) }
    %w[p1 p2 p3].each { |peer| watching(peer, suggest_mid) }
    watching("p1", suggest_weak)
    watching("viewer1", c) # user сам в c; suggestions НЕ должны его включать
    watching("p1", c); watching("p2", c)

    described_class.call(user.id)

    cohort = PvaCohort.find_by(user_id: user.id)
    expect(cohort.cohort_method).to eq("co_watch")
    logins = cohort.suggestions.map { |s| s["login"] }
    expect(logins).to eq(%w[summit1g ludwig mizkif]) # DESC by pct, no user-channels
    expect(cohort.suggestions.first).to include("login" => "summit1g", "pct" => 80)
  end

  it "filters out suggestions below MIN_PCT (10%) and caps at MAX_SUGGESTIONS (5)" do
    a, b = channel("xqc"), channel("shroud")
    watching("viewer1", a); watching("viewer1", b)
    # 20 peers разделяют каналы с user
    20.times { |i| name = "peer#{i}"; watching(name, a); watching(name, b) }
    # 6 кандидатов с разным pct
    candidates = 6.times.map { |i| channel("cand#{i}") }
    # cand0: 20 peers (100%), cand1: 18 (90%), cand2: 15 (75%), cand3: 12 (60%), cand4: 10 (50%), cand5: 1 (5% < MIN_PCT)
    20.times { |i| watching("peer#{i}", candidates[0]) }
    18.times { |i| watching("peer#{i}", candidates[1]) }
    15.times { |i| watching("peer#{i}", candidates[2]) }
    12.times { |i| watching("peer#{i}", candidates[3]) }
    10.times { |i| watching("peer#{i}", candidates[4]) }
    watching("peer0", candidates[5])

    described_class.call(user.id)

    cohort = PvaCohort.find_by(user_id: user.id)
    expect(cohort.suggestions.size).to eq(5)
    expect(cohort.suggestions.map { |s| s["login"] }).to eq(%w[cand0 cand1 cand2 cand3 cand4])
    expect(cohort.suggestions.map { |s| s["pct"] }).to all(be >= 10)
  end

  it "is idempotent — recompute replaces the same row" do
    a, b, s = channel("a"), channel("b"), channel("suggest")
    watching("viewer1", a); watching("viewer1", b)
    %w[p1 p2 p3 p4 p5].each do |peer|
      watching(peer, a); watching(peer, b); watching(peer, s)
    end

    described_class.call(user.id)
    described_class.call(user.id)

    expect(PvaCohort.where(user_id: user.id).count).to eq(1)
  end
end
