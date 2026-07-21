# frozen_string_literal: true

require "rails_helper"

RSpec.describe SocialAnalytics::Telegram::PublicProfile do
  # Minimal HTML mirroring the t.me/s/<ch> preview structure the parser targets.
  def page(subs:, posts:)
    bubbles = posts.map do |views, at, reactions|
      react_html = reactions ? %(<div class="tgme_widget_message_reactions"><span class="tgme_reaction"><i class="emoji">👍</i>#{reactions}</span></div>) : ""
      %(<div class="tgme_widget_message_bubble">
          <a class="tgme_widget_message_date"><time datetime="#{at}"></time></a>
          #{react_html}
          <span class="tgme_widget_message_views">#{views}</span>
        </div>)
    end.join
    %(<html><div class="tgme_channel_info_header_title"><span>Recrent</span></div>
      <div class="tgme_channel_info_counter">#{subs} subscribers</div>#{bubbles}</html>)
  end

  describe ".parse" do
    let(:html) do
      page(subs: "236K", posts: [
        [ "70K", "2026-07-08T12:00:00+00:00", "700" ],
        [ "60K", "2026-07-09T12:00:00+00:00", "600" ],
        [ "50K", "2026-07-10T12:00:00+00:00", "500" ],
        [ "40K", "2026-07-11T12:00:00+00:00", "400" ]
      ])
    end

    it "extracts subscribers, title, posts and derived metrics (incl. reactions/ER)" do
      r = described_class.parse(html, handle: "recrent")

      expect(r[:handle]).to eq("recrent")
      expect(r[:title]).to eq("Recrent")
      expect(r[:subscribers]).to eq(236_000)
      expect(r[:posts].size).to eq(4)
      expect(r[:posts].first).to include(views: 70_000)

      m = r[:metrics]
      expect(m[:posts_on_page]).to eq(4)
      expect(m[:avg_views]).to eq(55_000)                 # (70+60+50+40)/4 K
      expect(m[:view_sub_ratio]).to eq(23.3)              # 55000/236000
      expect(m[:avg_reactions]).to eq(550)                # (700+600+500+400)/4
      expect(m[:er_percent]).to eq(1.0)                   # 550 / 55000
      expect(m[:view_cv]).to be_within(0.01).of(0.202)    # natural spread
      expect(m[:post_span_days]).to eq(3.0)
      expect(m[:median_gap_hours]).to eq(24.0)
    end

    it "parses M/K/spaced number formats" do
      expect(described_class.to_i("2.99M")).to eq(2_990_000)
      expect(described_class.to_i("236K")).to eq(236_000)
      expect(described_class.to_i("1 234")).to eq(1_234)
      expect(described_class.to_i("garbage")).to be_nil
    end

    it "returns nil for a page with no channel signal" do
      expect(described_class.parse("<html>nothing here</html>")).to be_nil
    end
  end
end
