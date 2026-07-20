# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Streamer my-channel page", type: :request do
  it "renders the faithful export markup with the wiring bundle (public shell, JS gates on auth)" do
    get "/app/channel"

    expect(response).to have_http_status(:ok)
    expect(response.body).to include('data-pencil-name="Hero · Реальные зрители"')
    expect(response.body).to include('data-pencil-name="Reputation · 30 стримов"')
    expect(response.body).to include("landing/my_channel")
    expect(response.body).to include("landing/brand_nav")
  end

  it "does not shadow the public marketing pages" do
    get "/streamers"
    expect(response).to have_http_status(:ok)
    expect(response.body).not_to include('data-pencil-name="Hero · Реальные зрители"')
  end
end
