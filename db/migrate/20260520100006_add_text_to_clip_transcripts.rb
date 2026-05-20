# frozen_string_literal: true

# BUG-110-C: persist full transcript text. WhisperHttpClient parses result[:text]
# но без колонки worker его терял (consumers иначе должны join segments[].text).
# verbose_json fix (response_format) даёт segments + language; text column = O(1) read.
class AddTextToClipTranscripts < ActiveRecord::Migration[8.0]
  def change
    add_column :clip_transcripts, :text, :text
  end
end
