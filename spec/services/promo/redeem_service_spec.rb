# frozen_string_literal: true

require "rails_helper"

RSpec.describe Promo::RedeemService do
  let(:user) { create(:user, tier: "free") }

  def redeem(code_str, as: user)
    described_class.new(user: as, code: code_str).call
  end

  it "grants the tier, opens a promo subscription and records the redemption" do
    promo = PromoCode.create!(code: "HR-TRIAL1", kind: "trial", grants_tier: "premium",
                              duration_days: 14, max_redemptions: 1)

    result = redeem("hr-trial1") # case/space tolerant

    expect(result.ok).to be(true)
    expect(result.tier).to eq("premium")
    expect(result.expires_at).to be_within(1.minute).of(14.days.from_now)
    expect(user.reload.tier).to eq("premium")
    sub = user.subscriptions.last
    expect(sub).to have_attributes(tier: "premium", plan_type: "promo", is_active: true)
    expect(sub.billing_period_end).to be_within(1.minute).of(14.days.from_now)
    expect(promo.reload.redemptions_count).to eq(1)
  end

  it "lifetime code (nil duration) grants with no expiry" do
    PromoCode.create!(code: "HR-VIP", kind: "vip_lifetime", grants_tier: "premium", max_redemptions: 1)

    result = redeem("HR-VIP")

    expect(result.ok).to be(true)
    expect(result.expires_at).to be_nil
    expect(user.subscriptions.last.billing_period_end).to be_nil
  end

  it "never downgrades: business user redeeming a premium code keeps business" do
    biz = create(:user, tier: "business")
    PromoCode.create!(code: "HR-P", kind: "trial", grants_tier: "premium", duration_days: 14)

    expect(redeem("HR-P", as: biz).ok).to be(true)
    expect(biz.reload.tier).to eq("business")
  end

  it "rejects an unknown / inactive / expired code as PROMO_INVALID" do
    PromoCode.create!(code: "HR-OFF", kind: "trial", grants_tier: "premium", active: false)
    PromoCode.create!(code: "HR-OLD", kind: "trial", grants_tier: "premium", expires_at: 1.day.ago)

    expect(redeem("NOPE").error).to eq("PROMO_INVALID")
    expect(redeem("HR-OFF").error).to eq("PROMO_INVALID")
    expect(redeem("HR-OLD").error).to eq("PROMO_INVALID")
  end

  it "caps redemptions (PROMO_EXHAUSTED) and blocks double-redeem (PROMO_ALREADY_REDEEMED)" do
    PromoCode.create!(code: "HR-ONE", kind: "friend_referral", grants_tier: "premium",
                      duration_days: 30, max_redemptions: 1)

    expect(redeem("HR-ONE").ok).to be(true)
    expect(redeem("HR-ONE").error).to eq("PROMO_ALREADY_REDEEMED")
    expect(redeem("HR-ONE", as: create(:user, tier: "free")).error).to eq("PROMO_EXHAUSTED")
  end

  it "enqueues the confirmation mail only on a successful redeem (P7)" do
    PromoCode.create!(code: "HR-MAIL", kind: "trial", grants_tier: "premium",
                      duration_days: 14, max_redemptions: 1)

    expect { redeem("HR-MAIL") }.to have_enqueued_mail(PromoMailer, :activated)
    expect { redeem("HR-MAIL") }.not_to have_enqueued_mail(PromoMailer, :activated) # already redeemed
    expect { redeem("NOPE") }.not_to have_enqueued_mail(PromoMailer, :activated)
  end

  # CR iter-1 SF-1: the grant commits inside the transaction, the mail is enqueued after it. A Redis
  # blip in deliver_later used to escape #call → 500 on an already-granted tier, and the retry would
  # answer PROMO_ALREADY_REDEEMED (grant unrecoverable through the UI).
  it "still returns the grant when the mail enqueue fails" do
    user = create(:user, email: "po@example.com")
    PromoCode.create!(code: "HR-MAILFAIL", kind: "trial", grants_tier: "premium", duration_days: 14)
    allow(PromoMailer).to receive(:activated).and_raise(Redis::CannotConnectError.new("boom"))

    result = described_class.new(user: user, code: "HR-MAILFAIL").call

    expect(result.ok).to be true
    expect(result.granted_tier).to eq("premium")
    expect(user.reload.tier).to eq("premium")
  end
end
