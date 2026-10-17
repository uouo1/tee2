# frozen_string_literal: true

# A single filed observation of a fundamental, with the date it became public.
# Restatements are additional rows with their own `filed`; the runner only
# ever reads rows filed strictly before the date it is standing on (a filing
# dated t reaches EDGAR after that day's close).
class PitFact < ApplicationRecord
  CONCEPTS = %w[
    revenue operating_income dep_amort net_income eps
    cash short_term_investments debt_current debt_noncurrent debt_total
    shares_cover shares_diluted
  ].freeze

  validates :cik, :concept, :period_end, :value, :filed, presence: true
  validates :concept, inclusion: { in: CONCEPTS }

  # Latest observation of a concept known on `as_of` (filed before it),
  # optionally only annual (10-K) rows, optionally no older than
  # `period_end_after`.
  def self.known_on(cik, concept, as_of, annual_only: true, period_end_after: nil)
    scope = where(cik: cik, concept: concept).where("filed < ?", as_of)
    scope = scope.where(form: %w[10-K 10-K/A]) if annual_only
    scope = scope.where("period_end >= ?", period_end_after) if period_end_after
    scope.order(period_end: :desc, filed: :desc).first
  end
end
