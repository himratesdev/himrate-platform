# frozen_string_literal: true

# TASK-033 FR-007: TI Divergence detection for merged streams.
# Compares TI between adjacent parts. |TI diff| > 20 → Telegram alert.
# Alert delivery delegated to TelegramAlertWorker (async, with Sidekiq retry).

class TiDivergenceAlerter
  DIVERGENCE_THRESHOLD = 20

  # Check all adjacent part pairs for TI divergence.
  # Only runs for merged streams (merged_parts_count > 1).
  def self.check(stream)
    return unless stream.merged_parts_count > 1

    ti_values = collect_ti_values(stream)
    return if ti_values.size < 2

    ti_values.each_cons(2).with_index do |(ti_a, ti_b), idx|
      next if ti_a.nil? || ti_b.nil?

      divergence = (ti_b - ti_a).abs
      next unless divergence > DIVERGENCE_THRESHOLD

      enqueue_alert(
        stream: stream,
        part_from: idx + 1,
        part_to: idx + 2,
        ti_from: ti_a,
        ti_to: ti_b,
        divergence: divergence
      )
    end
  end

  # Collect trust values from part_boundaries + final row.
  # PR3b (T1-074, M13b): under ti_v2_engine the axis is `authenticity` (same 0-100 scale —
  # DIVERGENCE_THRESHOLD=20 stays meaningful; raw ERV counts are V-scale-dependent, wrong axis).
  # Boundaries written pre-cutover carry only "ti_score" → per-boundary fallback keeps merged
  # streams spanning the flip alertable.
  def self.collect_ti_values(stream)
    boundaries = stream.part_boundaries || []

    if v2_engine?
      values = boundaries.map { |b| b["authenticity"] || b["ti_score"] }
      final = TrustIndexHistory.where(stream_id: stream.id, engine_version: "v2")
                               .order(calculated_at: :desc)
                               .pick(:authenticity)
    else
      values = boundaries.map { |b| b["ti_score"] }
      final = TrustIndexHistory.where(stream_id: stream.id, engine_version: "v1")
                               .order(calculated_at: :desc)
                               .pick(:trust_index_score)
    end
    values << final&.to_f
    values
  end

  def self.v2_engine?
    Flipper.enabled?(:ti_v2_engine)
  rescue StandardError
    false
  end

  def self.enqueue_alert(stream:, part_from:, part_to:, ti_from:, ti_to:, divergence:)
    text = <<~MSG.strip
      🟡 TI Divergence Alert
      Channel: #{stream.channel.login}
      Stream: #{stream.id}
      Part #{part_from}→#{part_to}: #{divergence.round(1)} points
      TI values: #{ti_from.round(1)} → #{ti_to.round(1)}
    MSG

    TelegramAlertWorker.perform_async(text)

    Rails.logger.info(
      "TiDivergenceAlerter: alert enqueued for stream #{stream.id} " \
      "(part #{part_from}→#{part_to}, diff=#{divergence.round(1)})"
    )
  end
end
