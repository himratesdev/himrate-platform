# frozen_string_literal: true

module TrustIndex
  module V2
    # Resolves the L2 per-cell honest baseline ρ* for a stream's cell (category × V-bucket × chat-mode
    # × language) from calibration_cell_baselines (SRS FR-003 / R-007). Exact cell first, then the
    # "default" category, then up the parent_cell chain for a sparse/uncalibrated cell (hierarchical
    # shrinkage). Returns the resolved baseline or nil (caller decides cold-start / conservative default).
    class CellResolver
      Baseline = Data.define(:rho_star, :rho_lo, :rho_hi)

      def self.call(category:, v_bucket:, chat_mode:, language:)
        cell = CalibrationCellBaseline.for_cell(
          category: category, v_bucket: v_bucket, chat_mode: chat_mode, language: language
        ) || CalibrationCellBaseline.for_cell(
          category: "default", v_bucket: v_bucket, chat_mode: chat_mode, language: language
        )
        return nil unless cell

        r = cell.resolved
        Baseline.new(rho_star: r.rho_star, rho_lo: r.rho_lo, rho_hi: r.rho_hi)
      end
    end
  end
end
