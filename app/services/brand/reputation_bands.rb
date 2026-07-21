# frozen_string_literal: true

module Brand
  # Canonical reputation-band → RU label map, shared by every brand surface that renders a band
  # (streamer card #348, compare #23, ...) so the wording stays identical. First-time-user-clarity:
  # each band term is spelled out. Keys are the exact BandService enum (impeccable/stable/variable/
  # unstable); nil band (cold-start) → nil label.
  module ReputationBands
    # Surface-audit sweep: the RU labels live in ONE place — config/locales/reputation.ru.yml
    # (T1-064 §10A canonical). This module used to duplicate them as a hardcoded constant
    # (byte-identical, but two sources drift). The emitted field is band_label_ru by contract,
    # hence the explicit locale: :ru (NOT request locale). Unknown/nil band → nil (cold-start).
    def self.label_ru(band)
      return nil if band.nil?

      I18n.t("reputation.band.#{band}", locale: :ru, default: nil)
    end
  end
end
