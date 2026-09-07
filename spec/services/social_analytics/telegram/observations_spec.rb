# frozen_string_literal: true

require "rails_helper"

# Socials get DESCRIPTIVE observations, never a fraud verdict (that lives on Twitch, where we watch
# viewers second by second). These specs pin both halves: the observation fires on the right numbers,
# and it names the benign explanation when the posts show one.
RSpec.describe SocialAnalytics::Telegram::Observations do
  def profile(metrics, posts = [])
    { metrics: metrics, posts: posts }
  end

  def codes(result)
    result.map(&:code)
  end

  it "flags more views than subscribers" do
    result = described_class.call(profile({ view_sub_ratio: 1019.7 }))

    expect(codes(result)).to include("VIEW_ABOVE_SUBS")
    expect(result.first.text).to include("Просмотров больше, чем подписчиков")
    expect(result.first.tone).to eq("warn")
  end

  it "softens that observation to informational when the posts were reposted" do
    result = described_class.call(profile({ view_sub_ratio: 300.0 }), posts_context: { reposted: true })

    obs = result.find { |o| o.code == "VIEW_ABOVE_SUBS" }
    expect(obs.text).to include("расходятся по другим каналам")
    expect(obs.tone).to eq("info")
  end

  it "flags near-identical view counts across posts" do
    posts = Array.new(8) { { views: 1000 } }
    result = described_class.call(profile({ view_cv: 0.01, view_sub_ratio: 40 }, posts))

    expect(codes(result)).to include("FLAT_VIEWS")
  end

  it "flags a silent audience (views without reactions)" do
    result = described_class.call(profile({ er_percent: 0.1, avg_views: 5_000, view_sub_ratio: 40 }))

    expect(codes(result)).to include("LOW_REACTIONS")
  end

  it "explains a single outlier post as a giveaway when the text says so" do
    posts = [ { views: 500 }, { views: 520 }, { views: 480 }, { views: 510 },
              { views: 9_000, text: "Розыгрыш! Дарим подписку" } ]
    result = described_class.call(profile({ view_sub_ratio: 40 }, posts))

    spike = result.find { |o| o.code == "VIEW_SPIKE" }
    expect(spike.text).to include("похоже на розыгрыш")
    expect(spike.tone).to eq("info")
  end

  it "says nothing about an ordinary channel" do
    posts = [ { views: 900 }, { views: 1_100 }, { views: 1_000 }, { views: 1_300 }, { views: 800 } ]
    result = described_class.call(profile({ view_sub_ratio: 45, view_cv: 0.28, er_percent: 6.0,
                                            avg_views: 1_000 }, posts))

    expect(result).to be_empty
  end
end
