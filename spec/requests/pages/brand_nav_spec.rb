# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Brand dashboard shared nav bundle", type: :request do
  %w[/app/search /app/compare /app/overlap /app/streamers/shadowkek].each do |route|
    it "includes the shared brand_nav chrome bundle on #{route}" do
      get route
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("landing/brand_nav")
    end
  end

  it "does not load brand_nav on a public marketing page" do
    get "/streamers"
    expect(response).to have_http_status(:ok)
    expect(response.body).not_to include("landing/brand_nav")
  end
end
