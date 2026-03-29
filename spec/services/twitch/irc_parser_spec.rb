# frozen_string_literal: true

require "rails_helper"

RSpec.describe Twitch::IrcParser do
  let(:parser) { described_class.new }

  describe "#parse" do
    # TC-002: PRIVMSG with full tags
    it "parses PRIVMSG with complete IRC tags" do
      line = "@badge-info=subscriber/24;badges=subscriber/24,bits/1000;color=#FF0000;" \
             "display-name=CoolGamer42;emotes=25:0-4;first-msg=0;id=abc-123-def;" \
             "returning-chatter=1;subscriber=1;user-type=mod;vip=0 " \
             ":coolgamer42!coolgamer42@coolgamer42.tmi.twitch.tv PRIVMSG #xqc :LOL nice play"

      result = parser.parse(line)

      expect(result).not_to be_nil
      expect(result.command).to eq("PRIVMSG")
      expect(result.channel_login).to eq("xqc")
      expect(result.username).to eq("coolgamer42")
      expect(result.message_text).to eq("LOL nice play")
      expect(result.msg_type).to eq("privmsg")
      expect(result.tags["display-name"]).to eq("CoolGamer42")
      expect(result.tags["badge-info"]).to eq("subscriber/24")
      expect(result.tags["subscriber"]).to eq("1")
      expect(result.tags["first-msg"]).to eq("0")
      expect(result.tags["returning-chatter"]).to eq("1")
      expect(result.tags["emotes"]).to eq("25:0-4")
      expect(result.tags["user-type"]).to eq("mod")
      expect(result.tags["color"]).to eq("#FF0000")
      expect(result.tags["id"]).to eq("abc-123-def")
    end

    # TC-003: USERNOTICE sub
    it "parses USERNOTICE sub event" do
      line = "@badge-info=subscriber/1;badges=subscriber/0;display-name=NewSub;" \
             "msg-id=sub;msg-param-cumulative-months=1;msg-param-sub-plan=1000 " \
             ":tmi.twitch.tv USERNOTICE #streamer :PogChamp first sub!"

      result = parser.parse(line)

      expect(result.command).to eq("USERNOTICE")
      expect(result.msg_type).to eq("sub")
      expect(result.channel_login).to eq("streamer")
      expect(result.tags["msg-param-cumulative-months"]).to eq("1")
      expect(result.tags["msg-param-sub-plan"]).to eq("1000")
    end

    # TC-004: USERNOTICE resub with badge-info
    it "parses USERNOTICE resub with badge-info" do
      line = "@badge-info=subscriber/24;badges=subscriber/24;display-name=LongTimeSub;" \
             "msg-id=resub;msg-param-cumulative-months=24;msg-param-sub-plan=1000 " \
             ":tmi.twitch.tv USERNOTICE #streamer :24 months and counting!"

      result = parser.parse(line)

      expect(result.msg_type).to eq("resub")
      expect(result.tags["badge-info"]).to eq("subscriber/24")
      expect(result.tags["msg-param-cumulative-months"]).to eq("24")
    end

    # TC-005: USERNOTICE raid with viewers
    it "parses USERNOTICE raid with viewer count" do
      line = "@msg-id=raid;msg-param-viewerCount=5000;display-name=RaidLeader;" \
             "login=raidleader " \
             ":tmi.twitch.tv USERNOTICE #target"

      result = parser.parse(line)

      expect(result.msg_type).to eq("raid")
      expect(result.tags["msg-param-viewerCount"]).to eq("5000")
      expect(result.channel_login).to eq("target")
    end

    # TC-006: ROOMSTATE
    it "parses ROOMSTATE with channel settings" do
      line = "@emote-only=0;followers-only=10;r9k=0;slow=30;subs-only=0 " \
             ":tmi.twitch.tv ROOMSTATE #channel"

      result = parser.parse(line)

      expect(result.command).to eq("ROOMSTATE")
      expect(result.msg_type).to eq("roomstate")
      expect(result.channel_login).to eq("channel")
      expect(result.tags["followers-only"]).to eq("10")
      expect(result.tags["slow"]).to eq("30")
      expect(result.tags["subs-only"]).to eq("0")
      expect(result.tags["emote-only"]).to eq("0")
    end

    # TC-007: CLEARCHAT ban with duration (timeout)
    it "parses CLEARCHAT timeout" do
      line = "@ban-duration=600;room-id=12345;target-user-id=67890 " \
             ":tmi.twitch.tv CLEARCHAT #channel :baduser"

      result = parser.parse(line)

      expect(result.command).to eq("CLEARCHAT")
      expect(result.msg_type).to eq("clearchat")
      expect(result.channel_login).to eq("channel")
      expect(result.message_text).to eq("baduser")
      expect(result.tags["ban-duration"]).to eq("600")
    end

    # TC-007b: CLEARCHAT permanent ban (no ban-duration)
    it "parses CLEARCHAT permanent ban" do
      line = "@room-id=12345;target-user-id=67890 " \
             ":tmi.twitch.tv CLEARCHAT #channel :banneduser"

      result = parser.parse(line)

      expect(result.msg_type).to eq("clearchat")
      expect(result.tags).not_to have_key("ban-duration")
      expect(result.message_text).to eq("banneduser")
    end

    # TC-008: CLEARMSG
    it "parses CLEARMSG with target message ID" do
      line = "@login=deleteduser;target-msg-id=msg-abc-123 " \
             ":tmi.twitch.tv CLEARMSG #channel :deleted message text"

      result = parser.parse(line)

      expect(result.command).to eq("CLEARMSG")
      expect(result.msg_type).to eq("clearmsg")
      expect(result.tags["target-msg-id"]).to eq("msg-abc-123")
      expect(result.tags["login"]).to eq("deleteduser")
    end

    # TC-015: PING
    it "parses PING message" do
      result = parser.parse("PING :tmi.twitch.tv")

      expect(result.command).to eq("PING")
      expect(result.msg_type).to eq("ping")
      expect(result.message_text).to eq("tmi.twitch.tv")
    end

    # TC-016: RECONNECT
    it "parses RECONNECT message" do
      result = parser.parse("RECONNECT")

      expect(result.command).to eq("RECONNECT")
      expect(result.msg_type).to eq("reconnect")
    end

    # TC-018: Malformed line
    it "returns nil for malformed IRC line" do
      result = parser.parse("this is not a valid IRC message")

      expect(result).to be_nil
    end

    # TC-019: Unknown tags preserved in raw_tags
    it "preserves unknown tags in parsed result" do
      line = "@unknown-future-tag=value123;display-name=User " \
             ":user!user@user.tmi.twitch.tv PRIVMSG #channel :hello"

      result = parser.parse(line)

      expect(result.tags["unknown-future-tag"]).to eq("value123")
      expect(result.tags["display-name"]).to eq("User")
    end

    it "returns nil for empty line" do
      expect(parser.parse("")).to be_nil
      expect(parser.parse(nil)).to be_nil
    end

    it "returns nil for numeric IRC replies" do
      result = parser.parse(":tmi.twitch.tv 001 justinfan1234 :Welcome, GLHF!")
      expect(result).to be_nil
    end

    it "handles PRIVMSG with bits" do
      line = "@bits=100;display-name=Cheerer " \
             ":cheerer!cheerer@cheerer.tmi.twitch.tv PRIVMSG #channel :cheer100 nice"

      result = parser.parse(line)

      expect(result.tags["bits"]).to eq("100")
    end

    it "handles VIP tag" do
      line = "@vip=1;display-name=VipUser " \
             ":vipuser!vipuser@vipuser.tmi.twitch.tv PRIVMSG #channel :hello"

      result = parser.parse(line)

      expect(result.tags["vip"]).to eq("1")
    end
  end

  describe "#to_record" do
    it "converts ParsedMessage to chat_messages record hash" do
      line = "@badge-info=subscriber/12;display-name=TestUser;first-msg=1;" \
             "returning-chatter=0;subscriber=1;user-type=;vip=0;color=#00FF00;" \
             "bits=50;id=msg-uuid-123;emotes=25:0-4 " \
             ":testuser!testuser@testuser.tmi.twitch.tv PRIVMSG #streamer :Kappa hello"

      parsed = parser.parse(line)
      record = parser.to_record(parsed, stream_id: "stream-uuid")

      expect(record[:stream_id]).to eq("stream-uuid")
      expect(record[:channel_login]).to eq("streamer")
      expect(record[:username]).to eq("testuser")
      expect(record[:message_text]).to eq("Kappa hello")
      expect(record[:msg_type]).to eq("privmsg")
      expect(record[:display_name]).to eq("TestUser")
      expect(record[:subscriber_status]).to eq("1")
      expect(record[:badge_info]).to eq("subscriber/12")
      expect(record[:is_first_msg]).to be true
      expect(record[:returning_chatter]).to be false
      expect(record[:emotes]).to eq("25:0-4")
      expect(record[:vip]).to be false
      expect(record[:color]).to eq("#00FF00")
      expect(record[:bits_used]).to eq(50)
      expect(record[:twitch_msg_id]).to eq("msg-uuid-123")
      expect(record[:raw_tags]).to be_a(Hash)
      expect(record[:raw_tags]["badge-info"]).to eq("subscriber/12")
      expect(record[:timestamp]).to be_a(Time)
    end

    it "handles CLEARCHAT target user" do
      line = "@ban-duration=600 :tmi.twitch.tv CLEARCHAT #channel :baduser"

      parsed = parser.parse(line)
      record = parser.to_record(parsed)

      expect(record[:username]).to eq("baduser")
      expect(record[:msg_type]).to eq("clearchat")
    end

    it "returns nil for nil input" do
      expect(parser.to_record(nil)).to be_nil
    end
  end
end
