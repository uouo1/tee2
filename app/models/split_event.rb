# frozen_string_literal: true

# One stock split: `ratio` is shares after per share before (4:1 -> 4.0, a
# 1:10 reverse split -> 0.1). Used to recover the unadjusted close from a
# split-adjusted price series and to roll a cover-page share count forward.
class SplitEvent < ApplicationRecord
  validates :ticker, :date, :ratio, presence: true
  validates :ratio, numericality: { greater_than: 0 }
end
