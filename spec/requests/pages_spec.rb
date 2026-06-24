# frozen_string_literal: true

require "rails_helper"

# TASK-060 Phase 0: the public marketing landing root. Landing is a public,
# unauthenticated surface and must stay reachable as later phases add the
# literal-ported pages — guard root from silently breaking (build-complete-now).
RSpec.describe "Public landing", type: :request do
  describe "GET /" do
    it "renders the landing root as public HTML with 200 (no auth)" do
      get "/"

      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq("text/html")
    end

    it "is Russian-first: <html lang=ru> by default" do
      get "/"

      expect(response.body).to include('lang="ru"')
    end

    it "switches locale via ?locale=en" do
      get "/", params: { locale: "en" }

      expect(response.body).to include('lang="en"')
    end

    it "falls back to ru for an unsupported locale" do
      get "/", params: { locale: "zz" }

      expect(response.body).to include('lang="ru"')
    end

    it "serves widest reach: a legacy browser UA is not blocked (no 406)" do
      get "/", headers: { "HTTP_USER_AGENT" => "Mozilla/5.0 (Windows NT 6.1) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/50.0.2661.102 Safari/537.36" }

      expect(response).to have_http_status(:ok)
    end
  end
end
