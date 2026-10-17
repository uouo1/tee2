# frozen_string_literal: true

# Consensus estimate rows (is_estimate = true) say where they came from, e.g.
# "consensus (Yahoo Finance, 9 analysts)", so an NTM multiple can be footnoted.
class AddEstimateSourceToFinancials < ActiveRecord::Migration[8.1]
  def change
    add_column :financials, :estimate_source, :string
  end
end
