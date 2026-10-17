# frozen_string_literal: true

# Audit fixes for the valuation bridge (docs/AUDIT.md):
# * financials gain a period_type ("FY" or "LTM") and the period end date, so a
#   trailing-twelve-month row can sit beside the fiscal-year rows and the DCF
#   can place a stub period from the real year end;
# * market_data records WHEN the balance sheet behind net_debt is dated and from
#   which form, plus the other claims an EV bridge deducts (non-controlling
#   interest, preferred equity) and a note when no debt line was tagged.
class AddValuationBridgeAndLtm < ActiveRecord::Migration[8.1]
  def change
    add_column :financials, :period_type, :string, null: false, default: "FY"
    add_column :financials, :period_end, :date
    remove_index :financials, name: "index_financials_on_company_id_and_fiscal_year"
    add_index :financials, [:company_id, :fiscal_year, :period_type], unique: true

    add_column :market_data, :net_debt_as_of, :date
    add_column :market_data, :balance_sheet_form, :string
    add_column :market_data, :minority_interest, :float
    add_column :market_data, :preferred_equity, :float
    add_column :market_data, :debt_note, :string
  end
end
