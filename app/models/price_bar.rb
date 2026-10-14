# frozen_string_literal: true

class PriceBar < ApplicationRecord
  validates :ticker, :month_end, presence: true
end
