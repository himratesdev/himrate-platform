# frozen_string_literal: true

require "rails_helper"

# Incident 2026-08-05: a documentation comment placed INSIDE the ALL_FLAGS %i[] percent-literal
# became ~40 whitespace-split symbol "flags" (:the, :boot, :"2026-07-29.", :"#", …) — %i[] has
# no comment syntax — and the boot loop registered + enabled every one of them on each Rails
# boot. These specs pin the flag-name shape so any future comment-token pollution (or a stray
# non-snake_case name) fails CI instead of silently polluting the Flipper registry.
RSpec.describe FlipperDefaults, "flag registry hygiene" do
  {
    "ALL_FLAGS" => FlipperDefaults::ALL_FLAGS,
    "STAGING_ALL_FLAGS" => FlipperDefaults::STAGING_ALL_FLAGS,
    "HOOK_FLAGS" => FlipperDefaults::HOOK_FLAGS.keys
  }.each do |registry, flags|
    describe registry do
      it "is non-empty" do
        expect(flags).not_to be_empty
      end

      flags.each do |flag|
        it "#{flag.inspect} is a snake_case symbol" do
          expect(flag).to be_a(Symbol)
          expect(flag.to_s).to match(/\A[a-z][a-z0-9_]*\z/)
        end
      end
    end
  end

  it "has no duplicate registrations across the three registries" do
    all = FlipperDefaults::ALL_FLAGS +
          FlipperDefaults::STAGING_ALL_FLAGS +
          FlipperDefaults::HOOK_FLAGS.keys
    dupes = all.tally.select { |_, count| count > 1 }.keys
    expect(dupes).to be_empty
  end
end
