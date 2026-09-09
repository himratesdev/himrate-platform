# frozen_string_literal: true

# One account of a ring's shared pool, with the evidence a reader can check: in how many of the
# group's channels it co-fired, how many bursts, how wide its widest burst was, how metronomic its
# posting rhythm is (`interval_cv` near zero = automation), and whether the TI engine had already
# flagged it by name (`named_bot`).
class CoordinationAccount < ApplicationRecord
  belongs_to :coordination_group

  validates :username, presence: true

  scope :strongest, -> { order(named_bot: :desc, events: :desc, channels_in_group: :desc) }
end
