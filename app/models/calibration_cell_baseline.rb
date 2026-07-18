# frozen_string_literal: true

# T1-074 (TI v2) — per-cell honest chat/CCV baseline for L2 F_soft (SRS §5.1 / FR-003 / R-007;
# Glossary «ρ*»). Cell = category × V-bucket × chat-mode × language. rho_star (median → moves the
# ERV number), rho_lo (P5-10, honest≈0 → gates the label), rho_hi (interval). An UN-POISONABLE
# population quantity (not the channel's own ratio) → a farm cannot launder; lurker categories
# (asmr/music) carry their own low ρ*. A sparse cell resolves up the `parent_cell` chain
# (hierarchical shrinkage). ILLUSTRATIVE until GATE 0 (`calibrated=false`).
class CalibrationCellBaseline < ApplicationRecord
  belongs_to :parent_cell, class_name: "CalibrationCellBaseline", optional: true
  has_many :child_cells, class_name: "CalibrationCellBaseline", foreign_key: :parent_cell_id,
                         inverse_of: :parent_cell, dependent: :nullify

  validates :category, :v_bucket, :chat_mode, :language, presence: true
  validates :rho_star, :rho_lo, :rho_hi, presence: true, numericality: { greater_than: 0 }
  validate :interval_ordered

  # Exact-cell lookup. Returns nil when the cell is absent (caller walks `parent_cell` / decides
  # cold-start) — the engine, not the model, owns the "cell missing entirely" policy.
  def self.for_cell(category:, v_bucket:, chat_mode:, language:)
    find_by(category: category, v_bucket: v_bucket, chat_mode: chat_mode, language: language)
  end

  # Nearest calibrated ancestor (self if calibrated, else up the parent chain) — hierarchical
  # shrinkage fallback for a sparse / uncalibrated cell.
  def resolved
    node = self
    node = node.parent_cell while node.parent_cell && !node.calibrated
    node
  end

  private

  def interval_ordered
    return if [ rho_lo, rho_star, rho_hi ].any?(&:nil?)
    errors.add(:rho_lo, "must be ≤ rho_star ≤ rho_hi") unless rho_lo <= rho_star && rho_star <= rho_hi
  end
end
