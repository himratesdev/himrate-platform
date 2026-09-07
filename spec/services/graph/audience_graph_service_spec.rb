# frozen_string_literal: true

require "rails_helper"

# Source of truth for the graph is now the ClickHouse presence layer (monitored archive + farm
# capture), so the spec seeds CH — CI runs a real server. Logins are namespaced per example.
RSpec.describe Graph::AudienceGraphService do
  let(:login_a) { ns("alpha") }
  let(:login_b) { ns("beta") }
  let(:login_c) { ns("gamma") }
  let!(:ch_a) { create(:channel, login: login_a, is_monitored: true) }
  let!(:ch_b) { create(:channel, login: login_b, is_monitored: true) }
  let(:shared_users) { (1..6).map { |i| ns("user#{i}") } }

  before { Rails.cache.clear }

  it "builds nodes with audience/band/category and edges with shared counts + overlap share" do
    seed({ login_a => shared_users + [ ns("only_a1"), ns("only_a2") ], login_b => shared_users })
    create(:trust_index_history, channel: ch_a, band_color: "green", engine_version: "v2")
    create(:stream, channel: ch_a, game_name: "Dota 2", language: "ru")

    result = described_class.new.build

    expect(result[:basis]).to eq("chat_presence")
    expect(result[:basis_source]).to eq("clickhouse_presence")
    a_node = result[:nodes].find { |n| n[:login] == login_a }
    expect(a_node[:audience]).to eq(8)
    expect(a_node[:band]).to eq("green")
    expect(a_node[:category]).to eq("Dota 2")
    expect(a_node[:language]).to eq("RU")
    expect(a_node[:tracked]).to be(true)
    edge = result[:edges].find { |e| [ e[:a], e[:b] ].sort == [ login_a, login_b ].sort }
    expect(edge[:shared]).to eq(6)
    expect(edge[:share]).to eq(1.0) # 6 shared / min(8, 6)
  end

  it "drops pairs under the shared floor" do
    thin = (1..2).map { |i| ns("u#{i}") }
    seed({ login_a => thin, login_b => thin })

    edges = described_class.new.build[:edges]
    expect(edges.select { |e| [ e[:a], e[:b] ].include?(login_a) }).to be_empty
  end

  it "focus mode returns the ego circle incl. untracked neighbours, 404s an unknown login" do
    seed({ login_a => shared_users, login_b => shared_users, login_c => shared_users })
    # gamma has chat presence but no monitored Channel row → discovery node, no verdict
    create(:channel, login: login_c, is_monitored: false)

    result = described_class.new(focus: login_a).build

    expect(result[:focus]).to eq(login_a)
    logins = result[:nodes].map { |n| n[:login] }
    expect(logins).to include(login_a, login_b, login_c)
    gamma = result[:nodes].find { |n| n[:login] == login_c }
    expect(gamma[:band]).to eq("grey")

    expect(described_class.new(focus: "nope_#{SecureRandom.hex(3)}").build[:error]).to eq("CHANNEL_NOT_FOUND")
  end
end
