# frozen_string_literal: true

# The whole data model in one migration: the research corpus (documents,
# chunks, extracted KPIs), company fundamentals and market data, and the
# pitch-book side (decks, slides, comp sets, pinned evidence). Keeping both
# halves in one database is what lets "pin this passage onto slide 7" be a
# single transaction rather than an integration.
class CreateArgosSchema < ActiveRecord::Migration[8.1]
  def change
    create_table :companies do |t|
      t.string  :ticker, null: false
      t.string  :name, null: false
      t.string  :sector
      t.string  :industry
      t.string  :country
      t.string  :hq
      t.integer :employees
      t.string  :currency, default: "USD"
      t.text    :description
      t.boolean :is_private, default: false
      t.timestamps
    end
    add_index :companies, :ticker, unique: true

    create_table :financials do |t|
      t.references :company, null: false, foreign_key: { on_delete: :cascade }
      t.integer :fiscal_year, null: false
      t.boolean :is_estimate, default: false
      t.float :revenue
      t.float :ebitda
      t.float :ebit
      t.float :net_income
      t.float :eps
      t.float :dep_amort
      t.float :capex
      t.float :nwc_change
      t.float :tax_rate
    end
    add_index :financials, [:company_id, :fiscal_year], unique: true

    create_table :market_data do |t|
      t.references :company, null: false, foreign_key: { on_delete: :cascade }, index: { unique: true }
      t.date   :as_of
      t.float  :share_price
      t.float  :shares_diluted   # millions; diluted weighted average where filed, else cover-page basic
      t.float  :shares_basic     # millions; cover-page count, kept for disclosure
      t.float  :net_debt
      t.float  :week52_low
      t.float  :week52_high
      t.float  :beta
    end

    create_table :documents do |t|
      t.string  :external_id
      t.string  :title, null: false
      t.references :company, foreign_key: { on_delete: :nullify }
      t.string  :doc_type, null: false
      t.string  :source
      t.string  :author
      t.date    :published_at, null: false
      t.string  :language, default: "en"
      t.string  :url
      t.float   :sentiment, default: 0.0
      t.integer :word_count, default: 0
      t.text    :body, null: false
      t.timestamps
    end
    add_index :documents, :external_id, unique: true
    add_index :documents, :doc_type
    add_index :documents, :published_at

    create_table :chunks do |t|
      t.references :document, null: false, foreign_key: { on_delete: :cascade }
      t.integer :seq, null: false
      t.string  :speaker
      t.text    :text, null: false
      t.float   :sentiment, default: 0.0
    end

    create_table :kpis do |t|
      t.references :document, null: false, foreign_key: { on_delete: :cascade }
      t.references :chunk, foreign_key: { on_delete: :cascade }
      t.references :company, foreign_key: { on_delete: :nullify }
      t.string :metric, null: false
      t.float  :value
      t.string :unit
      t.string :period
      t.text   :context
    end
    add_index :kpis, [:company_id, :metric]

    create_table :transactions do |t|
      t.date   :announced_on, null: false
      t.string :target, null: false
      t.string :acquirer, null: false
      t.string :sector
      t.float  :ev
      t.float  :ev_revenue
      t.float  :ev_ebitda
      t.float  :premium_1day
      t.string :consideration
      t.text   :note
    end

    create_table :watchlists do |t|
      t.string :name, null: false
      t.timestamps
    end
    add_index :watchlists, :name, unique: true

    create_table :watchlist_items, id: false do |t|
      t.references :watchlist, null: false, foreign_key: { on_delete: :cascade }
      t.references :company, null: false, foreign_key: { on_delete: :cascade }
    end
    add_index :watchlist_items, [:watchlist_id, :company_id], unique: true

    create_table :saved_searches do |t|
      t.string  :name, null: false
      t.string  :query, null: false
      t.text    :filters, null: false, default: "{}"
      t.integer :last_seen_document_id, default: 0
      t.timestamps
    end

    create_table :pitchbooks do |t|
      t.string :title, null: false
      t.string :subtitle
      t.string :client_name
      t.references :target_company, foreign_key: { to_table: :companies, on_delete: :nullify }
      t.string :banker
      t.string :status, default: "draft"
      t.text   :assumptions, null: false, default: "{}"
      t.timestamps
    end

    create_table :slides do |t|
      t.references :pitchbook, null: false, foreign_key: { on_delete: :cascade }
      t.integer :seq, null: false
      t.string  :kind, null: false
      t.string  :title, null: false
      t.string  :subtitle
      t.text    :payload, null: false, default: "{}"
      t.boolean :is_pinned, default: false
    end
    add_index :slides, [:pitchbook_id, :seq]

    create_table :comp_members, id: false do |t|
      t.references :pitchbook, null: false, foreign_key: { on_delete: :cascade }
      t.references :company, null: false, foreign_key: { on_delete: :cascade }
      t.string :kind, null: false, default: "trading"
    end
    add_index :comp_members, [:pitchbook_id, :company_id, :kind], unique: true

    create_table :evidences do |t|
      t.references :pitchbook, null: false, foreign_key: { on_delete: :cascade }
      t.references :slide, foreign_key: { on_delete: :nullify }
      t.references :document, foreign_key: { on_delete: :nullify }
      t.references :chunk, foreign_key: { on_delete: :nullify }
      t.text   :quote, null: false
      t.text   :note
      t.timestamps
    end

    # The FTS5 index and its triggers cannot be expressed in schema.rb, so they
    # live in SearchIndex.ensure!, which is idempotent and also runs for tests.
    reversible do |dir|
      dir.up { SearchIndex.ensure! }
      dir.down { SearchIndex.drop! }
    end
  end
end
