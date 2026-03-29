# frozen_string_literal: true

# TASK-024: Twitch IRC message parser.
# Parses raw IRC lines into structured hashes.
# Supports: PRIVMSG, USERNOTICE, ROOMSTATE, CLEARCHAT, CLEARMSG, PING, RECONNECT.
# Reference: https://dev.twitch.tv/docs/irc/

module Twitch
  class IrcParser
    # IRC commands we handle
    HANDLED_COMMANDS = %w[PRIVMSG USERNOTICE ROOMSTATE CLEARCHAT CLEARMSG PING RECONNECT].freeze

    # USERNOTICE msg-id values that define the event type
    USERNOTICE_TYPES = %w[sub resub subgift submysterygift raid bitsbadgetier ritual announcement].freeze

    ParsedMessage = Data.define(
      :command,       # String: PRIVMSG, USERNOTICE, ROOMSTATE, CLEARCHAT, CLEARMSG, PING, RECONNECT
      :channel_login, # String or nil: channel name without #
      :username,      # String or nil: sender username
      :message_text,  # String or nil: message body
      :msg_type,      # String: privmsg, sub, resub, roomstate, clearchat, clearmsg, etc.
      :tags,          # Hash: all parsed IRC tags
      :raw_line       # String: original IRC line for debugging
    )

    # Parse a single IRC line into a ParsedMessage.
    # Returns nil for unhandled commands (numeric replies, CAP, etc.)
    def parse(raw_line)
      line = raw_line.to_s.chomp("\r\n").chomp("\n")
      return nil if line.empty?

      # PING is special — no tags, no prefix
      return parse_ping(line) if line.start_with?("PING")

      # RECONNECT — Twitch tells us to reconnect
      return ParsedMessage.new(
        command: "RECONNECT", channel_login: nil, username: nil,
        message_text: nil, msg_type: "reconnect", tags: {}, raw_line: line
      ) if line.strip == "RECONNECT" || line.include?("RECONNECT")

      tags, remainder = extract_tags(line)
      prefix, command, params = extract_parts(remainder)

      return nil unless HANDLED_COMMANDS.include?(command)

      channel_login = extract_channel(params)
      username = extract_username(prefix)
      message_text = extract_message(params)
      msg_type = determine_msg_type(command, tags)

      ParsedMessage.new(
        command: command,
        channel_login: channel_login,
        username: username,
        message_text: message_text,
        msg_type: msg_type,
        tags: tags,
        raw_line: line
      )
    rescue StandardError => e
      Rails.logger.warn("IrcParser: failed to parse line (#{e.message}): #{raw_line.to_s.truncate(200)}")
      nil
    end

    # Convert ParsedMessage to a hash suitable for chat_messages table insert.
    def to_record(parsed, stream_id: nil)
      return nil unless parsed

      {
        stream_id: stream_id,
        channel_login: parsed.channel_login,
        username: resolve_username(parsed),
        message_text: parsed.message_text,
        msg_type: parsed.msg_type,
        display_name: parsed.tags["display-name"],
        subscriber_status: parsed.tags["subscriber"],
        badge_info: parsed.tags["badge-info"],
        is_first_msg: parsed.tags["first-msg"] == "1",
        returning_chatter: parsed.tags["returning-chatter"] == "1",
        emotes: parsed.tags["emotes"].presence,
        user_type: parsed.tags["user-type"].presence,
        vip: parsed.tags["vip"] == "1",
        color: parsed.tags["color"].presence,
        bits_used: parsed.tags["bits"].to_i,
        twitch_msg_id: parsed.tags["id"],
        raw_tags: parsed.tags,
        timestamp: Time.current
      }
    end

    private

    def parse_ping(line)
      ParsedMessage.new(
        command: "PING",
        channel_login: nil,
        username: nil,
        message_text: line.sub(/^PING\s*:?/, ""),
        msg_type: "ping",
        tags: {},
        raw_line: line
      )
    end

    # Extract @tags section from IRC line.
    # Format: @key1=val1;key2=val2 :prefix COMMAND ...
    def extract_tags(line)
      if line.start_with?("@")
        space_idx = line.index(" ")
        return [ {}, line ] unless space_idx

        raw_tags = line[1...space_idx]
        remainder = line[(space_idx + 1)..]

        tags = {}
        raw_tags.split(";").each do |pair|
          key, value = pair.split("=", 2)
          tags[key] = unescape_tag_value(value.to_s)
        end

        [ tags, remainder ]
      else
        [ {}, line ]
      end
    end

    # IRC tag value escaping: https://ircv3.net/specs/extensions/message-tags.html
    def unescape_tag_value(value)
      value
        .gsub("\\s", " ")
        .gsub("\\n", "\n")
        .gsub("\\r", "\r")
        .gsub("\\:", ";")
        .gsub("\\\\", "\\")
    end

    # Extract prefix, command, and params from IRC line (after tags).
    # Format: :prefix COMMAND param1 param2 :trailing
    def extract_parts(line)
      prefix = nil
      remainder = line

      if remainder.start_with?(":")
        space_idx = remainder.index(" ")
        return [ nil, "", "" ] unless space_idx

        prefix = remainder[1...space_idx]
        remainder = remainder[(space_idx + 1)..]
      end

      # Split into command and params
      parts = remainder.split(" ", 2)
      command = parts[0].to_s.upcase
      params = parts[1].to_s

      [ prefix, command, params ]
    end

    # Extract channel name from params (removes # prefix).
    def extract_channel(params)
      match = params.match(/#(\S+)/)
      match ? match[1].downcase : nil
    end

    # Extract username from prefix (nick!user@host).
    def extract_username(prefix)
      return nil unless prefix

      bang_idx = prefix.index("!")
      bang_idx ? prefix[0...bang_idx].downcase : prefix.downcase
    end

    # Extract trailing message from params (after :).
    def extract_message(params)
      colon_idx = params.index(" :")
      colon_idx ? params[(colon_idx + 2)..] : nil
    end

    # Determine msg_type based on IRC command and tags.
    def determine_msg_type(command, tags)
      case command
      when "PRIVMSG"
        "privmsg"
      when "USERNOTICE"
        msg_id = tags["msg-id"].to_s.downcase
        USERNOTICE_TYPES.include?(msg_id) ? msg_id : "usernotice"
      when "ROOMSTATE"
        "roomstate"
      when "CLEARCHAT"
        "clearchat"
      when "CLEARMSG"
        "clearmsg"
      else
        command.downcase
      end
    end

    # For CLEARCHAT, the target user is in the message body, not the prefix (tmi.twitch.tv).
    # For CLEARMSG, the username is in the `login` tag.
    def resolve_username(parsed)
      case parsed.command
      when "CLEARCHAT"
        parsed.message_text&.strip.presence || parsed.username
      when "CLEARMSG"
        parsed.tags["login"].presence || parsed.username
      when "ROOMSTATE"
        nil
      else
        parsed.username
      end
    end
  end
end
