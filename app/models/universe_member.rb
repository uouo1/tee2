# frozen_string_literal: true

# One filer in a backtest universe for a given anchor year. Members without a
# current ticker or price history stay in the table with a dropout_reason: they
# are how the survivorship bias is measured rather than ignored.
class UniverseMember < ApplicationRecord
  validates :cik, :anchor_year, presence: true

  scope :priced, -> { where(has_prices: true) }
  scope :for_anchor, ->(year) { where(anchor_year: year) }
end
