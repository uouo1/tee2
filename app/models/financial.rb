# frozen_string_literal: true

# One period of a company's financials. `period_type` is "FY" for a fiscal year
# (actual or estimate) or "LTM" for the trailing twelve months to `period_end`,
# built from the latest 10-Q; an LTM row shares its fiscal_year with the last
# reported year it extends.
class Financial < ApplicationRecord
  PERIOD_TYPES = %w[FY LTM].freeze

  belongs_to :company
  validates :fiscal_year, presence: true, uniqueness: { scope: %i[company_id period_type] }
  validates :period_type, inclusion: { in: PERIOD_TYPES }

  scope :fiscal, -> { where(period_type: "FY") }
  scope :trailing, -> { where(period_type: "LTM") }

  def ltm? = period_type == "LTM"
end
