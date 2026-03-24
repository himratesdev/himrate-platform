# frozen_string_literal: true

class TiSignal < ApplicationRecord
  self.table_name = "signals"

  belongs_to :stream
end
