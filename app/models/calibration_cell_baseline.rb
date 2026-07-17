# frozen_string_literal: true

# T1-074 (TI v2) — per-cell honest chat/CCV baseline for L2 F_soft (SRS §4A / FR-003; Glossary «ρ*»).
# Cell = category × V-bucket × chat-mode × language. ρ*_c (median → moves the ERV number),
# ρ_lo_c (P5-10, honest≈0 → gates the label), ρ_hi_c (interval). An UN-POISONABLE population
# quantity (not the channel's own ratio) → a farm cannot launder; lurker categories (asmr/music)
# carry their own low ρ*. ILLUSTRATIVE until GATE 0 (calibrated=false).
class CalibrationCellBaseline < ApplicationRecord
  DEFAULT_CATEGORY = "default"
  DEFAULT_MODE = "open"
  DEFAULT_LANGUAGE = "ru"

  validates :category, :v_bucket, :chat_mode, :language, presence: true
  validates :rho_star, :rho_lo, :rho_hi, presence: true, numericality: { greater_than: 0 }
  validate :interval_ordered

  # Exact-cell lookup with hierarchical fallback (→ default category) so a sparse cell degrades to
  # its parent rather than raising. Returns nil if nothing matches (caller decides cold-start).
  def self.for_cell(category:, v_bucket:, chat_mode: DEFAULT_MODE, language: DEFAULT_LANGUAGE)
    find_by(category: category, v_bucket: v_bucket, chat_mode: chat_mode, language: language) ||
      find_by(category: DEFAULT_CATEGORY, v_bucket: v_bucket, chat_mode: DEFAULT_MODE, language: language) ||
      find_by(category: DEFAULT_CATEGORY, v_bucket: v_bucket, chat_mode: DEFAULT_MODE, language: DEFAULT_LANGUAGE)
  end

  private

  def interval_ordered
    return if [ rho_lo, rho_star, rho_hi ].any?(&:nil?)
    errors.add(:rho_lo, "must be ≤ rho_star ≤ rho_hi") unless rho_lo <= rho_star && rho_star <= rho_hi
  end
end
