# frozen_string_literal: true

require "rails_helper"

# TASK-060 Level 2: dynamic per-channel OG share images. The real SVG→PNG render is
# verified live on staging (Docker image ships librsvg + fonts); here we test the
# controller contract with the renderer stubbed — routing, content-type, CDN cache
# header, and the graceful fallback (a share preview must never 500).
RSpec.describe "OG images", type: :request do
  let(:png) { "\x89PNG\r\n\x1a\n".b + "fake".b }

  describe "GET /og/c/:login.png" do
    it "renders the channel card PNG with a CDN cache header" do
      channel = create(:channel, login: "ninja")
      allow(Og::ChannelCardImage).to receive(:new).with(channel).and_return(
        instance_double(Og::ChannelCardImage, call: png)
      )

      get "/og/c/ninja.png"

      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq("image/png")
      expect(response.body).to eq(png)
      expect(response.headers["Cache-Control"]).to include("s-maxage=86400")
    end

    it "falls back to the static brand image when the channel is unknown" do
      get "/og/c/does_not_exist.png"

      expect(response).to have_http_status(:redirect)
      expect(response.location).to match(%r{/assets/brand/logo-square-gradient[-\w]*\.svg})
    end

    it "falls back (never 500s) when rendering raises" do
      create(:channel, login: "boom")
      allow(Og::ChannelCardImage).to receive(:new).and_raise(StandardError, "vips down")

      get "/og/c/boom.png"

      expect(response).to have_http_status(:redirect)
      expect(response.location).to match(%r{/assets/brand/logo-square-gradient[-\w]*\.svg})
    end
  end
end
