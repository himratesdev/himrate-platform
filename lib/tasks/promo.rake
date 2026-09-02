# frozen_string_literal: true

# TASK-H8 Day-0: mint promo codes from ops (no admin panel yet — TASK-150.8).
#   NOTE="core testers" bin/rails "promo:mint[trial,5]"         # 5 codes, kind preset (NOTE required)
#   bin/rails "promo:mint[vip_lifetime,2]" NOTE="core testers"
#   TIER=business DAYS=14 MAX=1 bin/rails "promo:mint[brand_pack_trial,3]"
# Presets (overridable via TIER/DAYS/MAX env): see KIND_PRESETS.
namespace :promo do
  KIND_PRESETS = {
    "vip_lifetime"     => { tier: "premium",  days: nil, max: 1 },
    "influencer_90d"   => { tier: "premium",  days: 90,  max: 1 },
    "friend_referral"  => { tier: "premium",  days: 30,  max: 1 },
    "trial"            => { tier: "premium",  days: 14,  max: 1 },
    "brand_pack_trial" => { tier: "business", days: 14,  max: 1 },
    "stream_featured"  => { tier: "premium",  days: 30,  max: 1 }
  }.freeze

  desc "Report codes + redemptions: promo:report"
  task report: :environment do
    PromoCode.order(:created_at).find_each do |c|
      cap = c.max_redemptions || "∞"
      exp = c.expires_at ? c.expires_at.to_date : "—"
      puts format("%-14s %-16s %-8s %s/%s exp:%-10s active:%-5s note:%s",
                  c.code, c.kind, c.grants_tier, c.redemptions_count, cap, exp, c.active, c.note)
      c.promo_redemptions.includes(:user).order(:created_at).each do |r|
        who = r.user.email.presence || r.user.username
        upto = r.grant_expires_at ? r.grant_expires_at.to_date : "lifetime"
        puts format("    ↳ %-30s %-8s until:%-10s at:%s", who, r.granted_tier, upto, r.created_at.to_date)
      end
    end
  end

  desc "Mint promo codes: promo:mint[kind,count]"
  task :mint, %i[kind count] => :environment do |_t, args|
    kind = args[:kind].to_s
    preset = KIND_PRESETS.fetch(kind) { abort("unknown kind #{kind.inspect}; one of: #{KIND_PRESETS.keys.join(', ')}") }
    count = (args[:count] || 1).to_i.clamp(1, 200)

    tier = ENV.fetch("TIER", preset[:tier])
    days = ENV.key?("DAYS") ? ENV["DAYS"].presence&.to_i : preset[:days]
    max  = ENV.key?("MAX") ? ENV["MAX"].presence&.to_i : preset[:max]
    note = ENV["NOTE"].presence
    abort("NOTE is required — every minted batch must say who/why (e.g. NOTE=\"soft-launch wave 1\")") unless note

    count.times do
      code = "HR-#{SecureRandom.alphanumeric(8).upcase}"
      PromoCode.create!(code: code, kind: kind, grants_tier: tier,
                        duration_days: days, max_redemptions: max, note: note)
      puts code
    end
  end
end
