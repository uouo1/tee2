# frozen_string_literal: true

class Financial < ApplicationRecord
  belongs_to :company
  validates :fiscal_year, presence: true, uniqueness: { scope: :company_id }
end
