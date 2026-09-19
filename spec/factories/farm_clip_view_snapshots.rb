# frozen_string_literal: true

# EPIC FARM: point-in-time view_count of one farm clip — the only source of view velocity
# (it cannot be reconstructed retroactively).
FactoryBot.define do
  factory :farm_clip_view_snapshot do
    farm_clip
    view_count { 100 }
    captured_at { 1.hour.ago }
  end
end
