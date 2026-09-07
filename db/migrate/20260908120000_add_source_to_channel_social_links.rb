# frozen_string_literal: true

# Provenance for a channel's social links. Until now every row came from one place — the Twitch
# channel panel (`channel.socialMedias`). The chat harvester adds a second source, and the two must
# stay distinguishable: a link the streamer declared on Twitch is a statement of fact, a link mined
# from chat is an inference we made. Existing rows are stamped "twitch_panel"; the harvester writes
# "chat" and refuses to overwrite anything it did not write itself.
class AddSourceToChannelSocialLinks < ActiveRecord::Migration[8.0]
  def up
    add_column :channel_social_links, :source, :string, null: false, default: "twitch_panel"
    add_index :channel_social_links, %i[channel_id source]
  end

  def down
    remove_index :channel_social_links, %i[channel_id source]
    remove_column :channel_social_links, :source
  end
end
