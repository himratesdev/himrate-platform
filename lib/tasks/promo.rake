# frozen_string_literal: true

# TASK-H8 Day-0: mint promo codes from ops (no admin panel yet — TASK-150.8).
#   bin/rails "promo:mint[trial,5]"                             # 5 codes, kind preset
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

  desc "Mint promo codes: promo:mint[kind,count]"
  task :mint, %i[kind count] => :environment do |_t, args|
    kind = args[:kind].to_s
    preset = KIND_PRESETS.fetch(kind) { abort("unknown kind #{kind.inspect}; one of: #{KIND_PRESETS.keys.join(', ')}") }
    count = (args[:count] || 1).to_i.clamp(1, 200)

    tier = ENV.fetch("TIER", preset[:tier])
    days = ENV.key?("DAYS") ? ENV["DAYS"].presence&.to_i : preset[:days]
    max  = ENV.key?("MAX") ? ENV["MAX"].presence&.to_i : preset[:max]
    note = ENV["NOTE"].presence

    count.times do
      code = "HR-#{SecureRandom.alphanumeric(8).upcase}"
      PromoCode.create!(code: code, kind: kind, grants_tier: tier,
                        duration_days: days, max_redemptions: max, note: note)
      puts code
    end
  end
end
