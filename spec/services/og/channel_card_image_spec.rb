# frozen_string_literal: true

require "rails_helper"

# Unit-tests the OG card's real logic WITHOUT the libvips SVG→PNG step (CI lacks
# libvips/librsvg — that path is verified live on staging). Exercises the security-
# relevant pieces directly: avatar host allow-list, size cap, MIME-by-signature,
# XML escaping, truncation, and the fallback disc. (landing hardening)
RSpec.describe Og::ChannelCardImage do
  let(:channel) { build(:channel, login: "recrent", display_name: "Recrent", profile_image_url: avatar_url) }
  let(:avatar_url) { "https://static-cdn.jtvnw.net/jtv_user_pictures/abc.png" }
  let(:service) { described_class.new(channel) }

  def stub_avatar(body:, status: 200, content_length: nil)
    res = instance_double(Net::HTTPOK, content_length: content_length)
    allow(res).to receive(:is_a?).with(Net::HTTPSuccess).and_return(status == 200)
    allow(res).to receive(:read_body).and_yield(body)
    http = instance_double(Net::HTTP)
    allow(http).to receive(:request_get).and_yield(res)
    allow(Net::HTTP).to receive(:start).and_yield(http)
  end

  describe "#fetch_avatar_data_uri (via send)" do
    it "embeds a Twitch-CDN PNG avatar as a base64 data-URI" do
      stub_avatar(body: "\x89PNG\r\n".b + "data".b)
      expect(service.send(:fetch_avatar_data_uri)).to start_with("data:image/png;base64,")
    end

    it "detects a WebP avatar by signature (not mislabelled png)" do
      stub_avatar(body: "RIFF____WEBPVP8 ".b)
      expect(service.send(:fetch_avatar_data_uri)).to start_with("data:image/webp;base64,")
    end

    it "rejects a non-Twitch host (SSRF guard)" do
      channel.profile_image_url = "https://evil.example.com/x.png"
      expect(service.send(:fetch_avatar_data_uri)).to be_nil
    end

    it "rejects a non-HTTPS URL" do
      channel.profile_image_url = "http://static-cdn.jtvnw.net/x.png"
      expect(service.send(:fetch_avatar_data_uri)).to be_nil
    end

    it "aborts an oversized streamed body (memory-bomb guard)" do
      stub_avatar(body: ("\x89PNG".b + ("x" * (4 * 1024 * 1024))))
      expect(service.send(:fetch_avatar_data_uri)).to be_nil
    end

    it "rejects early via the Content-Length header pre-check" do
      stub_avatar(body: "\x89PNG".b, content_length: 5 * 1024 * 1024)
      expect(service.send(:fetch_avatar_data_uri)).to be_nil
    end

    it "returns nil for an unknown signature (invalid data-URI guard)" do
      stub_avatar(body: "not-an-image".b)
      expect(service.send(:fetch_avatar_data_uri)).to be_nil
    end

    it "returns nil (→ disc fallback) when the avatar is missing" do
      channel.profile_image_url = nil
      expect(service.send(:fetch_avatar_data_uri)).to be_nil
    end
  end

  describe "SVG safety" do
    it "escapes XML metacharacters in the channel name" do
      channel.display_name = %(A<b>&"z)
      expect(service.send(:xml_escape, channel.display_name)).to eq("A&lt;b&gt;&amp;&quot;z")
    end

    it "truncates long names with an ellipsis" do
      expect(service.send(:truncate, "a" * 30, 10)).to end_with("…")
      expect(service.send(:truncate, "short", 10)).to eq("short")
    end

    it "builds a 1200x630 SVG containing the channel name" do
      allow(service).to receive(:fetch_avatar_data_uri).and_return(nil) # disc fallback, no network
      svg = service.send(:build_svg)
      expect(svg).to include('width="1200"').and include('height="630"')
      expect(svg).to include("Recrent")
    end
  end
end
