# frozen_string_literal: true

require "rails_helper"

# Twitch Shared Chat (Stream Together) relays one viewer's message into every participating
# channel's IRC feed. Until 2026-09-12 the cross-channel queries read those relayed copies as
# independent presence, so a viewer watching one collab stream looked like an account posting in
# four channels in the same second — the exact shape the temporal bot signal is built to catch.
#
# Blast radius when it was measured: 3847 accounts flagged as bots, of which 2152 were ordinary
# viewers whose chat is ≥50% relay. Those flags feed temporal_recurrence → LlrCalibrator → each
# chatter's bot score → f_hard, which is SUBTRACTED from the channel's real-viewer estimate, across
# 860 channels. After the filter the same live 24h window returns 15 accounts, eleven of them named
# utility bots.
#
# Against a real ClickHouse, because the whole defect lives in the SQL: the worker spec stubs both
# query methods, so before this file the predicate was executed by no test at all.
RSpec.describe "Shared Chat filtering in cross-channel queries", :clickhouse do
  let(:client) { Clickhouse.client }

  # Unique per run — the CI ClickHouse is shared and these specs never clean up.
  let(:suffix) { SecureRandom.hex(4) }
  let(:relayed_user) { "viewer_#{suffix}" }
  let(:genuine_user) { "fleet_#{suffix}" }
  let(:base) { 5.minutes.ago.change(usec: 0) }

  def row(user, channel, room_id, offset_s, source_room_id: nil)
    tags = { "room-id" => room_id }
    tags["source-room-id"] = source_room_id if source_room_id
    {
      channel_login: channel, username: user, msg_type: "privmsg",
      message_text: "gg", raw_tags: JSON.generate(tags),
      timestamp: (base + offset_s).utc.strftime("%Y-%m-%d %H:%M:%S.%3N")
    }
  end

  before do
    skip "ClickHouse not reachable (set CLICKHOUSE_HOST + run clickhouse:setup)" unless client.ping

    client.insert("chat_messages", [
      # One viewer, one message, typed in channel A during a Stream Together with B and C.
      # Twitch tags the origin copy with source-room-id == room-id, and each relayed copy with the
      # ORIGIN's room id. Only the first is evidence that this person was watching that channel.
      row(relayed_user, "collab_a_#{suffix}", "111", 0, source_room_id: "111"),
      row(relayed_user, "collab_b_#{suffix}", "222", 0, source_room_id: "111"),
      row(relayed_user, "collab_c_#{suffix}", "333", 0, source_room_id: "111"),

      # An account that really does post into three unrelated channels in the same second. No
      # shared-chat tags at all — this is what the signal exists to find, and it must survive.
      row(genuine_user, "solo_a_#{suffix}", "444", 1),
      row(genuine_user, "solo_b_#{suffix}", "555", 1),
      row(genuine_user, "solo_c_#{suffix}", "666", 1),
      # A second burst, because the query needs event_count >= 2 to report an account.
      row(genuine_user, "solo_a_#{suffix}", "444", 60),
      row(genuine_user, "solo_b_#{suffix}", "555", 60),
      row(genuine_user, "solo_c_#{suffix}", "666", 60)
    ])
  end

  describe ".temporal_co_occurrence" do
    subject(:flagged) { Clickhouse::ChatQueries.temporal_co_occurrence(5).to_h { |r| [ r["username"], r ] } }

    it "does not flag a viewer whose apparent spread is Shared Chat relay" do
      expect(flagged).not_to have_key(relayed_user)
    end

    it "still flags an account that genuinely posts across channels" do
      expect(flagged[genuine_user]["max_concurrent"].to_i).to eq(3)
    end
  end

  describe ".cross_channel_edges" do
    subject(:edges) do
      Clickhouse::ChatQueries.cross_channel_edges(50, 100_000)
        .group_by { |r| r["username"] }
    end

    # The relayed copies would otherwise draw audience-overlap edges between channels this person
    # never watched — and that graph is what the public «паутинка» renders. Once the relay is gone
    # they are a single-channel chatter, and a single channel carries no overlap edge at all.
    it "drops the relayed viewer from the overlap cohort entirely" do
      expect(edges).not_to have_key(relayed_user)
    end

    it "keeps every channel of an account that posts independently" do
      channels = edges.fetch(genuine_user, []).map { |r| r["channel_login"] }
      expect(channels).to contain_exactly("solo_a_#{suffix}", "solo_b_#{suffix}", "solo_c_#{suffix}")
    end
  end
end
