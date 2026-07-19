# frozen_string_literal: true

module Brand
  # Canonical reputation-band → RU label map, shared by every brand surface that renders a band
  # (streamer card #348, compare #23, ...) so the wording stays identical. First-time-user-clarity:
  # each band term is spelled out. Keys are the exact BandService enum (impeccable/stable/variable/
  # unstable); nil band (cold-start) → nil label.
  module ReputationBands
    LABELS_RU = {
      "impeccable" => "Безупречная",
      "stable" => "Стабильная",
      "variable" => "Изменчивая",
      "unstable" => "Нестабильная"
    }.freeze

    def self.label_ru(band)
      LABELS_RU[band]
    end
  end
end
