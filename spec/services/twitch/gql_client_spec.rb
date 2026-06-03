# frozen_string_literal: true

require "rails_helper"

RSpec.describe Twitch::GqlClient do
  let(:client) { described_class.new }
  let(:gql_url) { "https://gql.twitch.tv/gql" }

  before do
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:fetch).with("TWITCH_GQL_CLIENT_ID", anything).and_return("test_client_id")
  end

  # === FR-001: BotCheck single user ===

  describe "#bot_check" do
    it "returns user profile with all fields (TC-001)" do
      stub_gql_request(body_includes: "BotCheck", response: bot_check_response("shroud"))

      result = client.bot_check(login: "shroud")
      expect(result).to be_a(Hash)
      expect(result[:login]).to eq("shroud")
      expect(result[:display_name]).to eq("shroud")
      expect(result[:created_at]).to eq("2013-06-03T22:00:00Z")
      expect(result[:is_partner]).to be true
      expect(result[:followers_count]).to eq(9_500_000)
      expect(result[:follows_count]).to eq(42)
      expect(result[:videos_count]).to eq(150)
      expect(result[:has_clips]).to be true
      # TASK-251.20: profile_view_count dropped — Twitch deprecated profileViewCount GQL field.
      expect(result).not_to have_key(:profile_view_count)
    end

    it "returns nil for non-existent user (TC-002)" do
      stub_gql_request(body_includes: "BotCheck", response: { data: { user: nil } })

      result = client.bot_check(login: "nonexistent_user_xyz")
      expect(result).to be_nil
    end

    it "returns nil for blank login" do
      result = client.bot_check(login: "")
      expect(result).to be_nil
    end

    it "returns stream data when user is live" do
      response = bot_check_response("live_user", live: true)
      stub_gql_request(body_includes: "BotCheck", response: response)

      result = client.bot_check(login: "live_user")
      expect(result[:stream]).to be_a(Hash)
      expect(result[:stream][:viewers_count]).to eq(32_000)
      expect(result[:stream][:type]).to eq("live")
    end
  end

  # === FR-002: Batch BotCheck ===

  describe "#batch_bot_check" do
    it "returns array of profiles in same order (TC-003)" do
      stub_gql_batch(
        size: 3,
        responses: [
          { data: { user: { id: "1", login: "user1", displayName: "User1", createdAt: "2020-01-01T00:00:00Z",
                            roles: {}, followers: { totalCount: 10 }, follows: { totalCount: 5 }, videos: { totalCount: 0 } } } },
          { data: { user: { id: "2", login: "user2", displayName: "User2", createdAt: "2021-01-01T00:00:00Z",
                            roles: {}, followers: { totalCount: 20 }, follows: { totalCount: 10 }, videos: { totalCount: 0 } } } },
          { data: { user: { id: "3", login: "user3", displayName: "User3", createdAt: "2022-01-01T00:00:00Z",
                            roles: {}, followers: { totalCount: 30 }, follows: { totalCount: 15 }, videos: { totalCount: 0 } } } }
        ]
      )

      result = client.batch_bot_check(logins: %w[user1 user2 user3])
      expect(result.size).to eq(3)
      expect(result[0][:login]).to eq("user1")
      expect(result[1][:login]).to eq("user2")
      expect(result[2][:login]).to eq("user3")
    end

    it "handles partial failure — successful items returned, errors as nil (TC-004)" do
      stub_gql_batch(
        size: 2,
        responses: [
          { data: { user: { id: "1", login: "real", displayName: "Real", createdAt: "2020-01-01T00:00:00Z",
                            roles: {}, followers: { totalCount: 10 }, follows: { totalCount: 5 }, videos: { totalCount: 0 } } } },
          { data: { user: nil }, errors: [ { message: "user not found" } ] }
        ]
      )

      result = client.batch_bot_check(logins: %w[real fake])
      expect(result[0][:login]).to eq("real")
      expect(result[1]).to be_nil
    end

    it "raises ArgumentError when batch > 35 (TC-020)" do
      expect { client.batch_bot_check(logins: Array.new(36, "user")) }
        .to raise_error(ArgumentError, /exceeds max 35/)
    end
  end

  # === FR-003: CommunityTab ===

  describe "#community_tab" do
    it "returns viewer list with all role buckets (TC-005, BUG-251.30 extended)" do
      stub_gql_request(body_includes: "CommunityTab", response: {
        data: { channel: { chatters: {
          broadcasters: [ { login: "streamer" } ],
          moderators: [ { login: "mod1" }, { login: "mod2" } ],
          vips: [ { login: "vip1" } ],
          staff: [],
          viewers: [ { login: "viewer1" }, { login: "viewer2" }, { login: "viewer3" } ],
          count: 7
        } } }
      })

      result = client.community_tab(channel_login: "streamer")
      expect(result[:broadcasters]).to eq(%w[streamer])
      expect(result[:moderators]).to eq(%w[mod1 mod2])
      expect(result[:vips]).to eq(%w[vip1])
      expect(result[:staff]).to eq([])
      expect(result[:viewers]).to eq(%w[viewer1 viewer2 viewer3])
      expect(result[:count]).to eq(7)
      # BUG-251.30: convenience accessors for downstream (AuthRatio + profile enrichment)
      expect(result[:total_present]).to eq(7) # 1 + 2 + 1 + 0 + 3
      expect(result[:all_logins]).to eq(%w[streamer mod1 mod2 vip1 viewer1 viewer2 viewer3])
    end

    it "tolerates missing role keys (older Twitch responses without staff)" do
      stub_gql_request(body_includes: "CommunityTab", response: {
        data: { channel: { chatters: {
          broadcasters: [ { login: "s" } ],
          moderators: nil,
          vips: nil,
          viewers: [ { login: "v" } ],
          count: 2
        } } }
      })

      result = client.community_tab(channel_login: "s")
      expect(result[:total_present]).to eq(2)
      expect(result[:all_logins]).to eq(%w[s v])
    end

    it "returns nil when integrity check fails" do
      stub_gql_request(body_includes: "CommunityTab", response: {
        data: { channel: { chatters: nil } },
        errors: [ { message: "failed integrity check" } ]
      })

      result = client.community_tab(channel_login: "protected")
      expect(result).to be_nil
    end
  end

  # === G-3 (BUG-251.31): Parallel CommunityTab sweep ===

  describe "#community_tab_parallel" do
    it "fires N concurrent CommunityTab calls and dedupes viewer unions" do
      # Stub returns the SAME payload to every concurrent request. WebMock can't
      # selectively rotate per-thread, but the dedupe path still exercises Set merge +
      # the per-call telemetry counters. (Live Twitch returns a different ~100-viewer
      # random sample each call — that's the runtime benefit; here we cover the merge
      # logic + telemetry shape.)
      stub_gql_request(body_includes: "CommunityTab", response: {
        data: { channel: { chatters: {
          broadcasters: [ { login: "streamer" } ],
          moderators: [ { login: "mod1" } ],
          vips: [ { login: "vip1" } ],
          staff: [],
          viewers: [ { login: "viewerA" }, { login: "viewerB" }, { login: "viewerC" } ],
          count: 350
        } } }
      })

      result = client.community_tab_parallel(channel_login: "streamer", concurrent_calls: 5)

      # Dedupe yields the same unique set as single call (because stub is identical),
      # but the merge path ran 5x and telemetry reflects the work.
      expect(result[:broadcasters]).to eq([ "streamer" ])
      expect(result[:moderators]).to eq([ "mod1" ])
      expect(result[:vips]).to eq([ "vip1" ])
      expect(result[:viewers].sort).to eq(%w[viewerA viewerB viewerC])
      expect(result[:count]).to eq(350) # max_count carried through from authoritative chatters.count
      expect(result[:total_present]).to eq(350)
      expect(result[:parallel_calls]).to eq(5)
      expect(result[:successful_calls]).to eq(5)
      expect(result[:unique_viewer_logins]).to eq(3)
      expect(result[:viewer_samples_total]).to eq(15) # 5 calls × 3 viewers/call
      expect(result[:dedupe_ratio]).to eq(0.2)         # 3 unique / 15 samples
    end

    it "clamps concurrent_calls to [1, 50]" do
      stub_gql_request(body_includes: "CommunityTab", response: {
        data: { channel: { chatters: {
          broadcasters: [], moderators: [], vips: [], staff: [],
          viewers: [ { login: "v1" } ], count: 1
        } } }
      })

      under = client.community_tab_parallel(channel_login: "s", concurrent_calls: 0)
      expect(under[:parallel_calls]).to eq(1)

      over = client.community_tab_parallel(channel_login: "s", concurrent_calls: 999)
      expect(over[:parallel_calls]).to eq(50)
    end

    it "returns nil when channel_login is blank" do
      expect(client.community_tab_parallel(channel_login: "")).to be_nil
      expect(client.community_tab_parallel(channel_login: nil)).to be_nil
    end

    it "returns nil when every thread errors (graceful aggregate failure)" do
      # Stub returns a GQL errors-only response (no `data.channel.chatters`).
      # community_tab's `data.dig(...,"chatters")` resolves to nil → community_tab returns nil
      # → parallel wrapper sees `results == []` after compact → returns nil.
      stub_gql_request(body_includes: "CommunityTab", response: { errors: [ { message: "boom" } ] })
      expect(client.community_tab_parallel(channel_login: "lost", concurrent_calls: 3)).to be_nil
    end

    it "falls back to sum_present when authoritative count is absent" do
      stub_gql_request(body_includes: "CommunityTab", response: {
        data: { channel: { chatters: {
          broadcasters: [ { login: "b" } ],
          moderators: [ { login: "m" } ],
          vips: [], staff: [],
          viewers: [ { login: "v" } ]
          # NB: no "count" key
        } } }
      })

      result = client.community_tab_parallel(channel_login: "s", concurrent_calls: 2)
      expect(result[:count]).to eq(3)         # 1 + 1 + 1 fallback
      expect(result[:total_present]).to eq(3)
    end
  end

  # === FR-004: GetChannelChattersCount ===

  describe "#channel_chatters_count" do
    it "returns integer count (TC-007)" do
      stub_gql_request(body_includes: "GetChattersCount", response: {
        data: { channel: { chatters: { count: 1500 } } }
      })

      result = client.channel_chatters_count(channel_login: "test")
      expect(result).to eq(1500)
    end
  end

  # === FR-005: UseViewCount ===

  describe "#view_count" do
    it "returns viewer count for live stream (TC-008)" do
      stub_gql_request(body_includes: "UseViewCount", response: {
        data: { user: { stream: { id: "123", viewersCount: 97_493 } } }
      })

      result = client.view_count(channel_login: "live_channel")
      expect(result).to eq(97_493)
    end

    it "returns nil for offline channel (TC-009)" do
      stub_gql_request(body_includes: "UseViewCount", response: {
        data: { user: { stream: nil } }
      })

      result = client.view_count(channel_login: "offline_channel")
      expect(result).to be_nil
    end
  end

  # === BUG-110-B: ClipVideoURL ===
  describe "#clip_video_url" do
    let(:clip_response) do
      {
        data: {
          clip: {
            playbackAccessToken: { signature: "abc123sig", value: "tok&en=val" },
            videoQualities: [
              { sourceURL: "https://cdn.example/clip-1080.mp4", quality: "1080", frameRate: 0 },
              { sourceURL: "https://cdn.example/clip-360.mp4", quality: "360", frameRate: 0 }
            ]
          }
        }
      }
    end

    it "returns signed lowest-quality sourceURL (audio identical, min download)" do
      stub_gql_request(body_includes: "ClipVideoURL", response: clip_response)

      url = client.clip_video_url(slug: "FrozenZanyRaccoonGrammarKing")
      expect(url).to start_with("https://cdn.example/clip-360.mp4?sig=abc123sig&token=")
      expect(url).to include(CGI.escape("tok&en=val"))
    end

    it "returns bare sourceURL when token/signature absent" do
      resp = { data: { clip: { playbackAccessToken: nil,
                               videoQualities: [ { sourceURL: "https://cdn.example/c.mp4", quality: "480", frameRate: 0 } ] } } }
      stub_gql_request(body_includes: "ClipVideoURL", response: resp)

      expect(client.clip_video_url(slug: "x")).to eq("https://cdn.example/c.mp4")
    end

    it "returns nil for private/deleted clip (clip null)" do
      stub_gql_request(body_includes: "ClipVideoURL", response: { data: { clip: nil } })
      expect(client.clip_video_url(slug: "deleted")).to be_nil
    end

    it "returns nil when no video qualities" do
      stub_gql_request(body_includes: "ClipVideoURL", response: { data: { clip: { videoQualities: [] } } })
      expect(client.clip_video_url(slug: "x")).to be_nil
    end

    it "returns nil for blank slug" do
      expect(client.clip_video_url(slug: "")).to be_nil
    end
  end

  # === FR-006: StreamMetadata ===

  describe "#stream_metadata" do
    it "returns stream info with broadcast settings (TC-010)" do
      stub_gql_request(body_includes: "StreamMetadata", response: {
        data: { user: {
          stream: { id: "123", viewersCount: 5000, type: "live", createdAt: "2026-03-28T16:00:00Z",
                    game: { id: "509658", name: "Just Chatting" },
                    freeformTags: [ { name: "English" }, { name: "IRL" } ] },
          broadcastSettings: { title: "Chill Stream", language: "EN",
                               game: { id: "509658", name: "Just Chatting" } }
        } }
      })

      result = client.stream_metadata(channel_login: "test")
      expect(result[:title]).to eq("Chill Stream")
      expect(result[:game_name]).to eq("Just Chatting")
      expect(result[:viewers_count]).to eq(5000)
      expect(result[:language]).to eq("EN")
      expect(result[:tags]).to eq(%w[English IRL])
    end
  end

  # === FR-007: ChatRoomState ===

  describe "#chat_room_state" do
    it "returns all chat settings (TC-011)" do
      stub_gql_request(body_includes: "ChatRoomState", response: {
        data: { user: { chatSettings: {
          followersOnlyDurationMinutes: 10,
          isSubscribersOnlyModeEnabled: true,
          slowModeDurationSeconds: 30,
          isEmoteOnlyModeEnabled: false,
          blockLinks: true,
          chatDelayMs: 0,
          requireVerifiedAccount: false
        } } }
      })

      result = client.chat_room_state(channel_login: "test")
      expect(result[:followers_only_duration_minutes]).to eq(10)
      expect(result[:subscriber_only_mode]).to be true
      expect(result[:slow_mode_duration_seconds]).to eq(30)
      expect(result[:emote_only_mode]).to be false
      expect(result[:block_links]).to be true
      expect(result[:chat_delay_ms]).to eq(0)
      expect(result[:require_verified_account]).to be false
    end
  end

  # === FR-008: ViewerCard ===

  describe "#viewer_card" do
    it "returns user profile (TC-012)" do
      stub_gql_request(body_includes: "ViewerCard", response: bot_check_response("pokimane"))

      result = client.viewer_card(target_login: "pokimane")
      expect(result[:login]).to eq("pokimane")
      expect(result[:is_partner]).to be true
    end
  end

  # === FR-009: ChannelAbout ===

  describe "#channel_about" do
    it "returns channel info with social media (TC-013)" do
      stub_gql_request(body_includes: "ChannelAbout", response: {
        data: { user: {
          id: "123", displayName: "TestStreamer", description: "Best streamer",
          primaryColorHex: "FF0000", profileImageURL: "https://img.twitch.tv/test.jpg",
          channel: { socialMedias: [
            { name: "twitter", title: "@test", url: "https://twitter.com/test" },
            { name: "youtube", title: "TestYT", url: "https://youtube.com/test" }
          ] }
        } }
      })

      result = client.channel_about(channel_login: "test")
      expect(result[:display_name]).to eq("TestStreamer")
      expect(result[:social_medias].size).to eq(2)
      expect(result[:social_medias].first[:name]).to eq("twitter")
    end
  end

  # === FR-014: UserFollowing ===

  describe "#user_following" do
    it "returns follows list with dates (TC-024)" do
      stub_gql_request(body_includes: "UserFollowing", response: {
        data: { user: { follows: {
          totalCount: 42,
          edges: [
            { cursor: "2024-01-15T10:00:00Z", node: { login: "streamer1" } },
            { cursor: "2024-02-20T15:00:00Z", node: { login: "streamer2" } }
          ],
          pageInfo: { hasNextPage: true, endCursor: "cursor_abc" }
        } } }
      })

      result = client.user_following(login: "test_user")
      expect(result[:total_count]).to eq(42)
      expect(result[:follows].size).to eq(2)
      expect(result[:follows].first[:login]).to eq("streamer1")
      expect(result[:has_next_page]).to be true
      expect(result[:cursor]).to eq("cursor_abc")
    end

    it "handles pagination with cursor (TC-025)" do
      stub_gql_request(body_includes: "UserFollowing", response: {
        data: { user: { follows: {
          totalCount: 100,
          edges: [ { cursor: "2024-03-01T00:00:00Z", node: { login: "page2_user" } } ],
          pageInfo: { hasNextPage: false, endCursor: nil }
        } } }
      })

      result = client.user_following(login: "test", first: 20, after: "cursor_abc")
      expect(result[:follows].first[:login]).to eq("page2_user")
      expect(result[:has_next_page]).to be false
    end
  end

  # === FR-015: ChannelLeaderboards ===

  describe "#channel_leaderboards" do
    it "returns bits leaderboard with id+score+rank (TC-026/TC-040)" do
      stub_gql_request(body_includes: "ChannelLeaderboards", response: {
        data: { user: { cheer: { leaderboard: { entries: { edges: [
          { node: { id: "1366665217", score: 2000, rank: 1 } },
          { node: { id: "9876543210", score: 1104, rank: 2 } }
        ] } } } } }
      })

      result = client.channel_leaderboards(channel_login: "test", first: 5)
      expect(result.size).to eq(2)
      expect(result.first[:id]).to eq("1366665217")
      expect(result.first[:score]).to eq(2000)
      expect(result.first[:rank]).to eq(1)
    end
  end

  # === FR-016: ActiveMods ===

  describe "#active_mods" do
    it "returns list of moderator logins (TC-027)" do
      stub_gql_request(body_includes: "ActiveMods", response: {
        data: { user: { mods: { edges: [
          { node: { login: "mod1" } },
          { node: { login: "mod2" } },
          { node: { login: "mod3" } }
        ] } } }
      })

      result = client.active_mods(channel_login: "test")
      expect(result).to eq(%w[mod1 mod2 mod3])
    end
  end

  # === FR-017: TopStreams ===

  describe "#top_streams" do
    it "returns live streams list (TC-028)" do
      stub_gql_request(body_includes: "TopStreams", response: {
        data: { streams: { edges: [
          { node: { broadcaster: { login: "xqc", displayName: "xQc" },
                    viewersCount: 90_000, game: { name: "Just Chatting" },
                    title: "LIVE", createdAt: "2026-03-28T16:00:00Z" } },
          { node: { broadcaster: { login: "kamet0", displayName: "Kamet0" },
                    viewersCount: 38_000, game: { name: "League of Legends" },
                    title: "Ranked", createdAt: "2026-03-28T15:00:00Z" } }
        ] } }
      })

      result = client.top_streams(first: 2)
      expect(result.size).to eq(2)
      expect(result.first[:login]).to eq("xqc")
      expect(result.first[:viewers_count]).to eq(90_000)
    end

    it "accepts game_id filter (TC-029)" do
      stub_gql_request(body_includes: "TopStreams", response: {
        data: { streams: { edges: [
          { node: { broadcaster: { login: "s1mple", displayName: "s1mple" },
                    viewersCount: 15_000, game: { name: "Counter-Strike" },
                    title: "FPL", createdAt: "2026-03-28T14:00:00Z" } }
        ] } }
      })

      result = client.top_streams(first: 10, game_id: "32399")
      expect(result.first[:game_name]).to eq("Counter-Strike")
    end
  end

  # === FR-010: Error handling ===

  describe "error handling" do
    it "retries on 429 with exponential backoff (TC-014)" do
      stub_request(:post, gql_url)
        .to_return(
          { status: 429 },
          { status: 429 },
          { status: 200, body: { data: { user: { stream: { id: "1", viewersCount: 100 } } } }.to_json,
            headers: { "Content-Type" => "application/json" } }
        )

      allow(client).to receive(:sleep)

      result = client.view_count(channel_login: "test")
      expect(result).to eq(100)
      expect(client).to have_received(:sleep).with(1).once
      expect(client).to have_received(:sleep).with(2).once
    end

    it "returns nil after max retries on 429 (TC-015)" do
      stub_request(:post, gql_url).to_return(status: 429)
      allow(client).to receive(:sleep)

      result = client.view_count(channel_login: "test")
      expect(result).to be_nil
    end

    it "returns nil on timeout (TC-016)" do
      stub_request(:post, gql_url).to_timeout

      result = client.bot_check(login: "test")
      expect(result).to be_nil
    end

    it "logs and returns nil on GQL errors (TC-017)" do
      stub_gql_request(body_includes: "BotCheck", response: {
        data: { user: nil },
        errors: [ { message: "some gql error" } ]
      })

      expect(Rails.logger).to receive(:error).with(/some gql error/)
      result = client.bot_check(login: "test")
      expect(result).to be_nil
    end

    it "returns nil on invalid JSON (TC-022)" do
      stub_request(:post, gql_url)
        .to_return(status: 200, body: "not json at all", headers: { "Content-Type" => "application/json" })

      result = client.bot_check(login: "test")
      expect(result).to be_nil
    end

    it "retries on 500 then succeeds (TC-023)" do
      stub_request(:post, gql_url)
        .to_return(
          { status: 500 },
          { status: 200, body: { data: { user: { stream: { id: "1", viewersCount: 200 } } } }.to_json,
            headers: { "Content-Type" => "application/json" } }
        )

      allow(client).to receive(:sleep)
      result = client.view_count(channel_login: "test")
      expect(result).to eq(200)
    end
  end

  # === FR-012: Client-ID configuration ===

  describe "Client-ID" do
    it "uses ENV value (TC-018)" do
      stub_request(:post, gql_url)
        .with(headers: { "Client-ID" => "test_client_id" })
        .to_return(status: 200, body: { data: { user: { stream: nil } } }.to_json,
                   headers: { "Content-Type" => "application/json" })

      client.view_count(channel_login: "test")
      expect(WebMock).to have_requested(:post, gql_url)
        .with(headers: { "Client-ID" => "test_client_id" })
    end

    it "falls back to default when ENV not set (TC-019)" do
      allow(ENV).to receive(:fetch).with("TWITCH_GQL_CLIENT_ID", anything)
        .and_return(Twitch::GqlClient::DEFAULT_CLIENT_ID)

      default_client = described_class.new

      stub_request(:post, gql_url)
        .to_return(status: 200, body: { data: { user: { stream: nil } } }.to_json,
                   headers: { "Content-Type" => "application/json" })

      default_client.view_count(channel_login: "test")
      # BUG-251.30: DEFAULT_CLIENT_ID switched from web `kimne78kx3ncx6brgo4mv6wki5h1ko`
      # (integrity-gated) to Android `kd1unb4b3q4t58fwlpcbzcbnm76a8fp` (bypasses Kasada).
      expect(WebMock).to have_requested(:post, gql_url)
        .with(headers: { "Client-ID" => "kd1unb4b3q4t58fwlpcbzcbnm76a8fp" })
    end

    it "DEFAULT_CLIENT_ID points to Android client (BUG-251.30)" do
      # Static guardrail: prevents accidental revert to web Client-ID which would re-trigger
      # integrity-gate on community_tab / socialMedias / hasPrime / etc.
      expect(Twitch::GqlClient::DEFAULT_CLIENT_ID).to eq("kd1unb4b3q4t58fwlpcbzcbnm76a8fp")
    end
  end

  # === Empty login edge case (TC-021) ===

  describe "empty login" do
    it "returns nil for nil login" do
      expect(client.bot_check(login: nil)).to be_nil
      expect(client.view_count(channel_login: nil)).to be_nil
      expect(client.stream_metadata(channel_login: nil)).to be_nil
    end
  end

  private

  def stub_gql_request(body_includes:, response:)
    stub_request(:post, gql_url)
      .with { |req| req.body.include?(body_includes) }
      .to_return(
        status: 200,
        body: response.to_json,
        headers: { "Content-Type" => "application/json" }
      )
  end

  def stub_gql_batch(size:, responses:)
    stub_request(:post, gql_url)
      .with { |req| JSON.parse(req.body).is_a?(Array) }
      .to_return(
        status: 200,
        body: responses.to_json,
        headers: { "Content-Type" => "application/json" }
      )
  end

  def bot_check_response(login, live: false)
    # TASK-251.20: profileViewCount removed — Twitch deprecated the field (always nil in production).
    {
      data: { user: {
        id: "12345", login: login, displayName: login,
        createdAt: "2013-06-03T22:00:00Z", description: "Pro gamer",
        profileImageURL: "https://img.twitch.tv/#{login}.jpg",
        chatColor: "#FF0000",
        roles: { isPartner: true, isAffiliate: false },
        followers: { totalCount: 9_500_000 }, follows: { totalCount: 42 },
        lastBroadcast: { startedAt: "2026-03-27T02:00:00Z", title: "Stream", game: { name: "Valorant" } },
        videos: { totalCount: 150 },
        clips: { edges: [ { node: { id: "clip1" } } ] },
        stream: live ? { id: "999", viewersCount: 32_000, game: { name: "Valorant" }, type: "live", createdAt: "2026-03-28T16:00:00Z" } : nil
      } }
    }
  end
end
