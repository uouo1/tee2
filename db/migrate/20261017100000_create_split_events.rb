# frozen_string_literal: true

# Stock splits per ticker, from the price source. Yahoo's monthly `close` is
# split-adjusted, so a market capitalisation at a past date needs the close
# multiplied back by every split that came after it (docs/BACKTEST.md).
class CreateSplitEvents < ActiveRecord::Migration[8.1]
  def change
    create_table :split_events do |t|
      t.string :ticker, null: false
      t.date   :date, null: false
      t.float  :ratio, null: false   # shares after per share before: a 4:1 split is 4.0
      t.string :source
    end
    add_index :split_events, [:ticker, :date], unique: true
  end
end
