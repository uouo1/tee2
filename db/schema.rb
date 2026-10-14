# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_10_14_060000) do
  create_table "backtest_runs", force: :cascade do |t|
    t.string "name", null: false
    t.text "params", default: "{}", null: false
    t.text "results", default: "{}", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end

  create_table "chunks", force: :cascade do |t|
    t.integer "document_id", null: false
    t.integer "seq", null: false
    t.string "speaker"
    t.text "text", null: false
    t.float "sentiment", default: 0.0
    t.index ["document_id"], name: "index_chunks_on_document_id"
  end

  create_table "comp_members", id: false, force: :cascade do |t|
    t.integer "pitchbook_id", null: false
    t.integer "company_id", null: false
    t.string "kind", default: "trading", null: false
    t.index ["company_id"], name: "index_comp_members_on_company_id"
    t.index ["pitchbook_id", "company_id", "kind"], name: "index_comp_members_on_pitchbook_id_and_company_id_and_kind", unique: true
    t.index ["pitchbook_id"], name: "index_comp_members_on_pitchbook_id"
  end

  create_table "companies", force: :cascade do |t|
    t.string "ticker", null: false
    t.string "name", null: false
    t.string "sector"
    t.string "industry"
    t.string "country"
    t.string "hq"
    t.integer "employees"
    t.string "currency", default: "USD"
    t.text "description"
    t.boolean "is_private", default: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["ticker"], name: "index_companies_on_ticker", unique: true
  end

  create_table "documents", force: :cascade do |t|
    t.string "external_id"
    t.string "title", null: false
    t.integer "company_id"
    t.string "doc_type", null: false
    t.string "source"
    t.string "author"
    t.date "published_at", null: false
    t.string "language", default: "en"
    t.string "url"
    t.float "sentiment", default: 0.0
    t.integer "word_count", default: 0
    t.text "body", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["company_id"], name: "index_documents_on_company_id"
    t.index ["doc_type"], name: "index_documents_on_doc_type"
    t.index ["external_id"], name: "index_documents_on_external_id", unique: true
    t.index ["published_at"], name: "index_documents_on_published_at"
  end

  create_table "evidences", force: :cascade do |t|
    t.integer "pitchbook_id", null: false
    t.integer "slide_id"
    t.integer "document_id"
    t.integer "chunk_id"
    t.text "quote", null: false
    t.text "note"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["chunk_id"], name: "index_evidences_on_chunk_id"
    t.index ["document_id"], name: "index_evidences_on_document_id"
    t.index ["pitchbook_id"], name: "index_evidences_on_pitchbook_id"
    t.index ["slide_id"], name: "index_evidences_on_slide_id"
  end

  create_table "financials", force: :cascade do |t|
    t.integer "company_id", null: false
    t.integer "fiscal_year", null: false
    t.boolean "is_estimate", default: false
    t.float "revenue"
    t.float "ebitda"
    t.float "ebit"
    t.float "net_income"
    t.float "eps"
    t.float "dep_amort"
    t.float "capex"
    t.float "nwc_change"
    t.float "tax_rate"
    t.index ["company_id", "fiscal_year"], name: "index_financials_on_company_id_and_fiscal_year", unique: true
    t.index ["company_id"], name: "index_financials_on_company_id"
  end

  create_table "kpis", force: :cascade do |t|
    t.integer "document_id", null: false
    t.integer "chunk_id"
    t.integer "company_id"
    t.string "metric", null: false
    t.float "value"
    t.string "unit"
    t.string "period"
    t.text "context"
    t.index ["chunk_id"], name: "index_kpis_on_chunk_id"
    t.index ["company_id", "metric"], name: "index_kpis_on_company_id_and_metric"
    t.index ["company_id"], name: "index_kpis_on_company_id"
    t.index ["document_id"], name: "index_kpis_on_document_id"
  end

  create_table "market_data", force: :cascade do |t|
    t.integer "company_id", null: false
    t.date "as_of"
    t.float "share_price"
    t.float "shares_diluted"
    t.float "shares_basic"
    t.float "net_debt"
    t.float "week52_low"
    t.float "week52_high"
    t.float "beta"
    t.index ["company_id"], name: "index_market_data_on_company_id", unique: true
  end

  create_table "pit_facts", force: :cascade do |t|
    t.integer "cik", null: false
    t.string "ticker"
    t.string "concept", null: false
    t.integer "fiscal_year"
    t.date "period_start"
    t.date "period_end", null: false
    t.float "value", null: false
    t.date "filed", null: false
    t.string "accession"
    t.string "form"
    t.string "tag"
    t.index ["cik", "concept", "filed"], name: "index_pit_facts_on_cik_and_concept_and_filed"
    t.index ["cik", "concept", "period_end", "filed"], name: "index_pit_facts_on_cik_and_concept_and_period_end_and_filed", unique: true
  end

  create_table "pitchbooks", force: :cascade do |t|
    t.string "title", null: false
    t.string "subtitle"
    t.string "client_name"
    t.integer "target_company_id"
    t.string "banker"
    t.string "status", default: "draft"
    t.text "assumptions", default: "{}", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["target_company_id"], name: "index_pitchbooks_on_target_company_id"
  end

  create_table "price_bars", force: :cascade do |t|
    t.string "ticker", null: false
    t.date "month_end", null: false
    t.float "close"
    t.float "adj_close"
    t.string "source"
    t.boolean "adjusted", default: true
    t.index ["ticker", "month_end"], name: "index_price_bars_on_ticker_and_month_end", unique: true
  end

  create_table "saved_searches", force: :cascade do |t|
    t.string "name", null: false
    t.string "query", null: false
    t.text "filters", default: "{}", null: false
    t.integer "last_seen_document_id", default: 0
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end

  create_table "slides", force: :cascade do |t|
    t.integer "pitchbook_id", null: false
    t.integer "seq", null: false
    t.string "kind", null: false
    t.string "title", null: false
    t.string "subtitle"
    t.text "payload", default: "{}", null: false
    t.boolean "is_pinned", default: false
    t.index ["pitchbook_id", "seq"], name: "index_slides_on_pitchbook_id_and_seq"
    t.index ["pitchbook_id"], name: "index_slides_on_pitchbook_id"
  end

  create_table "transactions", force: :cascade do |t|
    t.date "announced_on", null: false
    t.string "target", null: false
    t.string "acquirer", null: false
    t.string "sector"
    t.float "ev"
    t.float "ev_revenue"
    t.float "ev_ebitda"
    t.float "premium_1day"
    t.string "consideration"
    t.text "note"
  end

  create_table "universe_members", force: :cascade do |t|
    t.integer "cik", null: false
    t.string "ticker"
    t.string "name"
    t.string "sic"
    t.string "sic_description"
    t.string "exchange"
    t.string "loc"
    t.float "revenue_anchor"
    t.integer "anchor_year", null: false
    t.boolean "has_prices", default: false
    t.string "dropout_reason"
    t.datetime "selected_at"
    t.index ["anchor_year", "cik"], name: "index_universe_members_on_anchor_year_and_cik", unique: true
    t.index ["ticker"], name: "index_universe_members_on_ticker"
  end

  create_table "watchlist_items", id: false, force: :cascade do |t|
    t.integer "watchlist_id", null: false
    t.integer "company_id", null: false
    t.index ["company_id"], name: "index_watchlist_items_on_company_id"
    t.index ["watchlist_id", "company_id"], name: "index_watchlist_items_on_watchlist_id_and_company_id", unique: true
    t.index ["watchlist_id"], name: "index_watchlist_items_on_watchlist_id"
  end

  create_table "watchlists", force: :cascade do |t|
    t.string "name", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["name"], name: "index_watchlists_on_name", unique: true
  end

  add_foreign_key "chunks", "documents", on_delete: :cascade
  add_foreign_key "comp_members", "companies", on_delete: :cascade
  add_foreign_key "comp_members", "pitchbooks", on_delete: :cascade
  add_foreign_key "documents", "companies", on_delete: :nullify
  add_foreign_key "evidences", "chunks", on_delete: :nullify
  add_foreign_key "evidences", "documents", on_delete: :nullify
  add_foreign_key "evidences", "pitchbooks", on_delete: :cascade
  add_foreign_key "evidences", "slides", on_delete: :nullify
  add_foreign_key "financials", "companies", on_delete: :cascade
  add_foreign_key "kpis", "chunks", on_delete: :cascade
  add_foreign_key "kpis", "companies", on_delete: :nullify
  add_foreign_key "kpis", "documents", on_delete: :cascade
  add_foreign_key "market_data", "companies", on_delete: :cascade
  add_foreign_key "pitchbooks", "companies", column: "target_company_id", on_delete: :nullify
  add_foreign_key "slides", "pitchbooks", on_delete: :cascade
  add_foreign_key "watchlist_items", "companies", on_delete: :cascade
  add_foreign_key "watchlist_items", "watchlists", on_delete: :cascade
end
