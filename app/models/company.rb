# frozen_string_literal: true

class Company < ApplicationRecord
  has_many :financials, dependent: :destroy
  has_one  :market_datum, class_name: "MarketDatum", dependent: :destroy
  has_many :documents, dependent: :nullify
  has_many :kpis, dependent: :nullify
  has_many :watchlist_items, dependent: :destroy
  has_many :comp_members, dependent: :destroy

  validates :ticker, :name, presence: true
  validates :ticker, uniqueness: true

  before_validation { self.ticker = ticker.to_s.upcase.strip if ticker }

  scope :by_ticker, ->(ticker) { where(ticker: ticker.to_s.upcase) }

  def self.find_ticker(ticker)
    by_ticker(ticker).first
  end

  # Insert-or-update by ticker, mirroring the loader semantics.
  def self.upsert_by_ticker!(attrs)
    company = find_or_initialize_by(ticker: attrs[:ticker].to_s.upcase)
    company.assign_attributes(attrs.except(:ticker))
    company.save!
    company
  end

  def actual_financials
    financials.where(is_estimate: false).order(:fiscal_year)
  end
end
