# frozen_string_literal: true

require "rails_helper"

RSpec.describe SocialAnalytics::Youtube::PublicProfile do
  describe ".build / .compute_metrics (pure)" do
    let(:channel) do
      { channel_id: "UCabc", title: "Recrent Shorts", subscribers: 55_900,
        total_views: 65_762_244, video_count: 828, uploads_playlist: "UUabc" }
    end
    let(:videos) do
      [ { views: 200_000, likes: 6_000, comments: 400 },
        { views: 100_000, likes: 2_000, comments: 200 },
        { views: 90_000, likes: 1_600, comments: 200 } ]
    end

    it "assembles descriptive channel metrics + ER (no fraud verdict)" do
      r = described_class.build(channel, videos)

      expect(r).to include(title: "Recrent Shorts", subscribers: 55_900, total_views: 65_762_244, video_count: 828)
      m = r[:metrics]
      expect(m[:recent_videos]).to eq(3)
      expect(m[:avg_views]).to eq(130_000)                 # (200+100+90)k / 3
      expect(m[:avg_engagement]).to eq(3_467)              # ((6400)+(2200)+(1800))/3 ≈ 3466.6
      expect(m[:er_percent]).to eq(2.67)                   # 3467 / 130000
      expect(m[:views_per_sub]).to eq(1176.4)              # 65762244 / 55900
      expect(r).not_to have_key(:trust)                    # descriptive, no накрутка score
    end

    it "handles a hidden subscriber count / no videos gracefully" do
      r = described_class.build({ channel_id: "UCx", title: "X", subscribers: nil, total_views: 100, video_count: 5 }, [])
      expect(r[:subscribers]).to be_nil
      expect(r[:metrics][:avg_views]).to be_nil
      expect(r[:metrics][:er_percent]).to be_nil
      expect(r[:metrics][:views_per_sub]).to be_nil        # subs nil → no ratio
    end
  end

  describe "#resolve_channel_id" do
    it "reads a /channel/UC… id directly without a fetch" do
      p = described_class.new("https://www.youtube.com/channel/UCfBpmM8Ty4i93IIWXCK9EKQ")
      expect(p.resolve_channel_id).to eq("UCfBpmM8Ty4i93IIWXCK9EKQ")
    end
  end

  it "returns nil without an API key (no crash)" do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("YOUTUBE_API_KEY").and_return(nil)
    expect(described_class.call("https://www.youtube.com/@x")).to be_nil
  end
end
