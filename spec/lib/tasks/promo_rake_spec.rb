# frozen_string_literal: true

require "rails_helper"
require "rake"

# TASK-H8 CR iter-1: promo:mint gained a hard NOTE gate (a batch with no provenance is refused)
# and promo:report is new ops output — both are operator entry points, neither was covered.
RSpec.describe "promo rake tasks" do
  before(:all) { Rails.application.load_tasks if Rake::Task.tasks.empty? }

  before do
    Rake::Task.tasks.each(&:reenable)
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:key?).and_call_original
    allow(ENV).to receive(:fetch).and_call_original
  end

  describe "promo:mint" do
    it "aborts without NOTE and mints nothing" do
      allow(ENV).to receive(:[]).with("NOTE").and_return(nil)

      expect { Rake::Task["promo:mint"].invoke("trial", "2") }.to raise_error(SystemExit)
      expect(PromoCode.count).to eq(0)
    end

    it "aborts on an unknown kind" do
      expect { Rake::Task["promo:mint"].invoke("nonsense", "1") }.to raise_error(SystemExit)
      expect(PromoCode.count).to eq(0)
    end

    it "mints N codes on the kind preset and stamps the NOTE" do
      allow(ENV).to receive(:[]).with("NOTE").and_return("soft-launch wave 1")

      expect { Rake::Task["promo:mint"].invoke("trial", "2") }.to output(/HR-/).to_stdout

      expect(PromoCode.count).to eq(2)
      code = PromoCode.first
      expect(code).to have_attributes(kind: "trial", grants_tier: "premium",
                                      duration_days: 14, max_redemptions: 1,
                                      note: "soft-launch wave 1")
      expect(code.code).to match(/\AHR-[A-Z0-9]{8}\z/)
    end
  end

  describe "promo:report" do
    let(:user) { create(:user, email: "streamer@example.com") }

    before do
      promo = PromoCode.create!(code: "HR-REPORT1", kind: "vip_lifetime", grants_tier: "premium",
                                max_redemptions: 1, note: "core testers")
      PromoRedemption.create!(promo_code: promo, user: user, granted_tier: "premium")
    end

    it "prints the code, its note and who redeemed it" do
      expect { Rake::Task["promo:report"].invoke }.to output(
        a_string_including("HR-REPORT1").and(
          a_string_including("core testers").and(a_string_including("streamer@example.com"))
        )
      ).to_stdout
    end

    it "warns that the default output carries PII" do
      expect { Rake::Task["promo:report"].invoke }.to output(/CONTAINS PII/).to_stdout
    end

    it "masks the local part under MASK=1 (safe to paste)" do
      allow(ENV).to receive(:[]).with("MASK").and_return("1")

      # One invoke, both directions asserted: rake tasks are single-shot per `reenable`, so a
      # second `invoke` in the same example is a no-op and `not_to output(...)` would pass on any
      # code (CR iter-2 nit).
      expect { Rake::Task["promo:report"].invoke }.to output(
        a_string_including("st***@example.com")
          .and(a_string_including("emails masked"))
          .and(satisfy { |out| !out.include?("streamer@example.com") })
      ).to_stdout
    end
  end
end
