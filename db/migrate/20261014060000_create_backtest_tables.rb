# frozen_string_literal: true

# Backtest data (docs/BACKTEST.md): the point-in-time universe, every filed
# fundamental observation with the date it became public, monthly prices, and
# the runs themselves. Kept apart from the research tables because this data is
# wide (hundreds of filers, ten years) and never joined to the corpus.
class CreateBacktestTables < ActiveRecord::Migration[8.1]
  def change
    create_table :universe_members do |t|
      t.integer :cik, null: false
      t.string  :ticker
      t.string  :name
      t.string  :sic
      t.string  :sic_description
      t.string  :exchange
      t.string  :loc
      t.float   :revenue_anchor         # USD, anchor-year frame value
      t.integer :anchor_year, null: false
      t.boolean :has_prices, default: false
      t.string  :dropout_reason
      t.datetime :selected_at
    end
    add_index :universe_members, [:anchor_year, :cik], unique: true
    add_index :universe_members, :ticker

    create_table :pit_facts do |t|
      t.integer :cik, null: false
      t.string  :ticker
      t.string  :concept, null: false
      t.integer :fiscal_year
      t.date    :period_start
      t.date    :period_end, null: false
      t.float   :value, null: false      # raw units: USD or shares
      t.date    :filed, null: false
      t.string  :accession
      t.string  :form
      t.string  :tag                     # the us-gaap/dei tag the value came from
    end
    add_index :pit_facts, [:cik, :concept, :period_end, :filed], unique: true
    add_index :pit_facts, [:cik, :concept, :filed]

    create_table :price_bars do |t|
      t.string  :ticker, null: false
      t.date    :month_end, null: false
      t.float   :close
      t.float   :adj_close
      t.string  :source
      t.boolean :adjusted, default: true
    end
    add_index :price_bars, [:ticker, :month_end], unique: true

    create_table :backtest_runs do |t|
      t.string :name, null: false
      t.text   :params, null: false, default: "{}"
      t.text   :results, null: false, default: "{}"
      t.timestamps
    end
  end
end
