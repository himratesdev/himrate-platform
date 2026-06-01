# frozen_string_literal: true

# EPIC ML-FEATURE-EXTRACTOR PR2 (CR-249 M1): factory для ChattersSnapshot.
# Existing precedent `spec/workers/cleanup_worker_spec.rb` instantiated rows via
# direct `ChattersSnapshot.create!(...)` because no factory existed. PR2 specs use
# `create(:chatters_snapshot, ...)` extensively — factory registers it once for
# all PR2 + PR3-7 specs consuming chatters_snapshots data.
#
# Model validates `unique_chatters_count` presence (numericality ≥ 0); DB enforces
# `total_messages_count NOT NULL` (migration 20260324000008). Factory defaults satisfy
# both — randomised within plausible ranges (10-500 chatters, 50-2000 messages per
# snapshot tick).
FactoryBot.define do
  factory :chatters_snapshot do
    association :stream
    timestamp { Time.current }
    unique_chatters_count { rand(10..500) }
    total_messages_count { rand(50..2000) }
  end
end
