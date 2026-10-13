# frozen_string_literal: true

class MarketDatum < ApplicationRecord
  self.table_name = "market_data"
  belongs_to :company
end
