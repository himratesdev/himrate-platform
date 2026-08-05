# frozen_string_literal: true

# EPIC-64: presentation helpers for the public /top pages. Band tokens are the
# screen-64 design's Reliability-badge color pairs mapped onto the v2 band colors
# (yellow and amber share the design's single warning token). Inline styles — not
# Tailwind classes — because the color is chosen at render time and the Tailwind
# build only compiles literal class strings.
module PublicTopHelper
  BAND_TOKENS = {
    "green" => { dot: "#25D9A4", bg: "#10271F" },
    "yellow" => { dot: "#F6A823", bg: "#2A2008" },
    "amber" => { dot: "#F6A823", bg: "#2A2008" },
    "red" => { dot: "#FB4E55", bg: "#2C1316" },
    "grey" => { dot: "#9A9AA9", bg: "#1C1C24" }
  }.freeze

  def top_band_tokens(color)
    BAND_TOKENS[color] || BAND_TOKENS["grey"]
  end

  # 1240 → "1.24K", 853 → "853", 1_240_000 → "1.24M" — the design's compact format.
  def top_viewers_compact(value)
    return "—" if value.nil?

    number_to_human(value, format: "%n%u", precision: 3, significant: true,
                           separator: ".", delimiter: "",
                           units: { unit: "", thousand: "K", million: "M", billion: "B" })
  end

  def top_avatar_initials(name)
    initials = name.to_s.strip.split(/\s+/).filter_map { |w| w[0] }.join[0, 2].upcase
    initials.presence || "?"
  end
end
