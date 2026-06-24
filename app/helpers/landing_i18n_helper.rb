# frozen_string_literal: true

require "nokogiri"

# Server-side i18n for the public landing (TASK-060).
#
# WHY THIS EXISTS (deviation from ADR D4 "Rails I18n per-string keys"): the landing
# is a 7198-line literal port of the Pencil export with 736 translatable strings.
# Hand-keying every string into t('lp...') across that markup is intractable and
# breaks literal-port fidelity (the #1 rule — PO catches divergences). Instead the
# RU markup is ported verbatim (byte-faithful), and EN is produced by replaying the
# export's own dictionary (hr-i18n.js → config/landing_translations.yml) server-side
# over the rendered HTML's text nodes. RU is the verbatim fast path; EN is fully
# server-rendered (SEO) — not a client swap. Translations stay centralized in one
# dictionary (not hardcoded-duplicated), which is also the bridge to the CMS phase.
module LandingI18nHelper
  # { ru_leaf_text => en_text }, keys space-normalised. Loaded once at boot.
  LANDING_TRANS = YAML.safe_load_file(
    Rails.root.join("config/landing_translations.yml")
  ).fetch("en").freeze

  # Per-process cache of localized renders (landing content is static per deploy).
  HR_CACHE = {}

  # Localize a rendered landing HTML fragment to the current locale. RU returns the
  # input verbatim; other locales translate leaf text nodes via the dictionary,
  # preserving SVG (HTML5 parser keeps camelCase attrs) and surrounding whitespace.
  def hr_localize(html)
    return html.html_safe if I18n.locale == :ru

    (HR_CACHE["#{I18n.locale}:#{html.hash}"] ||= hr_translate_fragment(html)).html_safe
  end

  private

  def hr_translate_fragment(html)
    frag = Nokogiri::HTML5.fragment(html)
    frag.traverse do |node|
      next unless node.text?
      raw = node.content
      key = raw.strip.gsub(/\s+/, " ")
      next if key.empty?
      en = LANDING_TRANS[key]
      next unless en
      node.content = "#{raw[/\A\s*/]}#{en}#{raw[/\s*\z/]}"
    end
    frag.to_html
  end
end
