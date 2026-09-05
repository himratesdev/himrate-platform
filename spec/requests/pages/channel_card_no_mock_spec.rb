# frozen_string_literal: true

require "rails_helper"

# W2 anti-mock guard: the public /c/:login page is an SEO surface attached to a REAL streamer's
# name — its server HTML must never carry the Pencil export's invented numbers, the fake
# logged-in user, or the decorative search (site audit 2026-09-05).
RSpec.describe "Public channel card — no mock content", type: :request do
  let!(:channel) { create(:channel, login: "realstreamer") }

  it "serves no invented metrics, fake user or dead search in the server HTML" do
    get "/c/realstreamer"

    expect(response).to have_http_status(:ok)
    body = response.body
    [ "4 200", "5 000 показано", "Denis H.", "⌘K", "RU 78%", "+1 200",
      "лёгкий всплеск", "среднее 83%", "дип 74%", "8 сек назад" ].each do |mock|
      expect(body).not_to include(mock), "mock leaked to crawlers: #{mock.inspect}"
    end
  end

  it "keeps the guest chrome: login button + the three public nav targets" do
    get "/c/realstreamer"

    expect(response.body).to include("Guest Login")
    expect(response.body).to include("Nav · Главная")
    expect(response.body).to include("Nav · Куда пойти")
    expect(response.body).to include("Nav · Watchlists")
    expect(response.body).not_to include("Nav · Биржа")
  end

  it "avatar initials come from the real login" do
    get "/c/realstreamer"
    expect(response.body).to include("Re") # @login[0,2].capitalize
  end
end
