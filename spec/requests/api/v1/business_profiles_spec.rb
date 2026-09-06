# frozen_string_literal: true

require "rails_helper"

# ONBOARD-D0 (screen 72): business-account application — draft upsert, submit validation,
# lock after submit, approve! intro grant + widened expiry sweep.
RSpec.describe "Business profile API" do
  def auth_headers(user)
    { "Authorization" => "Bearer #{Auth::JwtService.encode_access(user.id)}" }
  end

  let(:user) { create(:user, tier: "free") }

  it "requires auth" do
    get "/api/v1/business_profile"
    expect(response).to have_http_status(:unauthorized)
  end

  it "returns status none before any draft" do
    get "/api/v1/business_profile", headers: auth_headers(user)
    expect(response.parsed_body.dig("data", "status")).to eq("none")
  end

  it "upserts a lenient draft" do
    put "/api/v1/business_profile", params: { org_type: "self_employed", company_name: "ИП Иванов" },
                                    headers: auth_headers(user)
    expect(response).to have_http_status(:ok)
    expect(user.reload.business_profile.status).to eq("draft")

    put "/api/v1/business_profile", params: { inn: "123456789012" }, headers: auth_headers(user)
    expect(user.business_profile.reload.inn).to eq("123456789012")
    expect(user.business_profile.company_name).to eq("ИП Иванов")
  end

  it "rejects submit with a malformed INN for ooo" do
    post "/api/v1/business_profile/submit",
         params: { org_type: "ooo", company_name: "ООО Ромашка", inn: "123", sphere: "Игры",
                   authority_confirmed: true },
         headers: auth_headers(user)
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body["error"]).to eq("VALIDATION_FAILED")
  end

  it "rejects submit without the authority checkbox" do
    post "/api/v1/business_profile/submit",
         params: { org_type: "ooo", company_name: "ООО Ромашка", inn: "1234567890", sphere: "Игры" },
         headers: auth_headers(user)
    expect(response).to have_http_status(:unprocessable_entity)
  end

  it "submit → pending + PO telegram alert, then the profile is locked" do
    expect(TelegramAlertWorker).to receive(:perform_async).with(a_string_including("Бизнес-заявка"))
    post "/api/v1/business_profile/submit",
         params: { org_type: "ooo", company_name: "ООО Ромашка", inn: "1234567890", sphere: "Игры",
                   authority_confirmed: true },
         headers: auth_headers(user)

    expect(response).to have_http_status(:created)
    expect(user.reload.business_profile.status).to eq("pending")

    put "/api/v1/business_profile", params: { company_name: "Другое" }, headers: auth_headers(user)
    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body["error"]).to eq("PROFILE_LOCKED")
  end

  it "approve! grants a 14-day business intro and the widened sweep closes it" do
    profile = create(:business_profile, user: user, status: "pending",
                     org_type: "ooo", company_name: "ООО Ромашка", inn: "1234567890",
                     sphere: "Игры", authority_confirmed: true)
    profile.approve!

    expect(user.reload.tier).to eq("business")
    sub = user.subscriptions.find_by(plan_type: "business_intro")
    expect(sub.is_active).to be(true)
    expect(sub.billing_period_end).to be_within(1.minute).of(14.days.from_now)

    sub.update!(billing_period_end: 1.hour.ago)
    PromoExpiryWorker.new.perform
    expect(sub.reload.is_active).to be(false)
    expect(user.reload.tier).to eq("free")
  end

  it "rejected profile is editable again and resubmittable" do
    create(:business_profile, user: user, status: "rejected", review_note: "нет сайта",
           org_type: "ip", inn: "123456789012")
    put "/api/v1/business_profile", params: { website: "https://example.com" }, headers: auth_headers(user)
    expect(response).to have_http_status(:ok)
    expect(user.business_profile.reload.status).to eq("draft")
  end
end
