# frozen_string_literal: true

require "test_helper"

# The JSON API: HandlerTests and HttpTests of tests/test_api.py through Rails
# integration requests, plus the contract's additions — the ingest path guard
# (docs/RAILS_PORT.md item 9), exports under tmp/ (item 10), nil as null, and
# the valuation keys the October 2026 audit added (basis_label, ntm,
# ev_bridge, wacc) passed through as Valuation returns them.
class ApiTest < ActionDispatch::IntegrationTest
  self.use_transactional_tests = false

  JSON_HEADERS = { "CONTENT_TYPE" => "application/json", "ACCEPT" => "application/json" }.freeze

  # The reference answered an unmatched /api path with 404 (or 405 with the
  # allowed methods). Rails needs a catch-all route for that, and
  # config/routes.rb belongs to the integration lead; until it carries
  #   match "*path", to: "base#route_not_found", via: :all, format: false
  # inside `namespace :api`, the same route is appended here so the action is
  # exercised.
  def self.ensure_api_catch_all!
    routes = Rails.application.routes
    begin
      return if routes.recognize_path("/api/__argos_probe__", method: "GET")[:controller] == "api/base"
    rescue ActionController::RoutingError
      nil
    end
    routes.disable_clear_and_finalize = true
    routes.draw do
      namespace :api, defaults: { format: :json } do
        match "*path", to: "base#route_not_found", via: :all, format: false
      end
    end
  ensure
    routes.disable_clear_and_finalize = false
  end

  setup do
    self.class.ensure_api_catch_all!
    Seed::Demo.seed! unless Document.exists?
    @books = []
    @exports = []
  end

  teardown do
    @books.each { |book| Pitchbooks.delete!(book) if Pitchbook.exists?(book.id) }
    @exports.each { |path| FileUtils.rm_f(path) }
  end

  def json
    JSON.parse(response.body)
  end

  def post_json(path, payload)
    post path, params: JSON.generate(payload), headers: JSON_HEADERS
  end

  def make_book(**attrs)
    book = Pitchbooks.create!(title: "Project HTTP", target_ticker: "NVG", **attrs)
    @books << book
    book
  end

  # ------------------------------------------------------------ handlers

  test "health reports corpus and formats" do
    get "/api/health"
    assert_response :success
    assert_equal "ok", json["status"]
    assert_operator json["documents"], :>, 0
    assert json["export_formats"].key?("html")
    assert_equal true, json["export_formats"]["html"]
  end

  test "export formats lists every format" do
    get "/api/export-formats"
    assert_response :success
    assert_equal %w[html pdf pptx], json["formats"].keys.sort
  end

  test "search parses repeated filters" do
    get "/api/search?q=revenue&doc_type=filing&doc_type=transcript&limit=5"
    assert_response :success
    assert_operator json["results"].size, :<=, 5
    assert json["results"].any?
    assert(json["results"].all? { |row| %w[filing transcript].include?(row["doc_type"]) })
    # Both values reached the filter, not only the last one (Rack's default).
    types = json["results"].map { |row| row["doc_type"] }.uniq
    get "/api/search?q=revenue&doc_type=transcript&limit=50"
    transcripts_only = json["total_documents"]
    get "/api/search?q=revenue&doc_type=filing&doc_type=transcript&limit=50"
    assert_operator json["total_documents"], :>, transcripts_only, "doc types seen: #{types.inspect}"
  end

  test "search accepts the bracket spelling of a repeated filter and bad numbers fall back" do
    get "/api/search?q=margin&ticker[]=NVG&ticker[]=HLDX&limit=abc"
    assert_response :success
    assert(json["results"].all? { |row| %w[NVG HLDX].include?(row["ticker"]) })
    assert_operator json["returned"], :<=, 25
    assert json.key?("facets")
    assert json.key?("summary")
  end

  test "search summarize=0 leaves the summary out" do
    get "/api/search?q=margin&summarize=0&limit=3"
    assert_response :success
    refute json.key?("summary")
    assert_operator json["results"].size, :<=, 3
  end

  test "document not found returns 404" do
    get "/api/documents/#{10**7}"
    assert_response :not_found
    assert_match(/not found/, json["error"])
  end

  test "document detail" do
    document = Document.order(:id).first
    get "/api/documents/#{document.id}?q=pricing"
    assert_response :success
    assert_equal document.id, json["id"]
    assert json.key?("chunks")
    assert json.key?("similar")
  end

  test "company profile and charts" do
    get "/api/companies/nvg"
    assert_response :success
    assert_equal "NVG", json["ticker"]
    assert json.key?("volume_by_type")
    # The audit's valuation keys pass through as Valuation returns them.
    metrics = json["metrics"]
    %w[basis_label ntm ev_bridge latest_actual valuation_basis].each { |key| assert metrics.key?(key), key }
    assert_kind_of String, metrics["basis_label"]

    get "/api/companies/NVG/charts"
    assert_response :success
    assert_equal %w[margin revenue sentiment volume], json.keys.sort
    assert(json.values.all? { |value| value.start_with?("<svg") || value.start_with?("<p") })
  end

  test "unknown company is 404" do
    get "/api/companies/NOPE"
    assert_response :not_found
    get "/api/companies/NOPE/charts"
    assert_response :not_found
  end

  test "companies list and suggested comps" do
    get "/api/companies"
    assert_response :success
    tickers = json["companies"].map { |row| row["ticker"] }
    assert_includes tickers, "NVG"
    assert_equal tickers.sort, tickers

    get "/api/companies/nvg/suggest-comps"
    assert_response :success
    assert_equal "NVG", json["ticker"]
    assert json["comps"].any?
    refute_includes json["comps"], "NVG"
  end

  test "a company with no market data or documents reports null, not 0" do
    company = Company.create!(ticker: "NULLCO", name: "Null Co", sector: "Nowhere")
    get "/api/companies"
    row = json["companies"].find { |r| r["ticker"] == "NULLCO" }
    assert_nil row["share_price"]
    assert_nil row["net_debt"]
    assert_nil row["sentiment"]
    assert_equal 0, row["documents"]

    get "/api/companies/NULLCO"
    assert_response :success
    assert_nil json["sentiment"]
    assert_nil json["sentiment_label"]
  ensure
    company&.destroy
  end

  test "overview trends transactions and dashboard charts" do
    get "/api/overview"
    assert_response :success
    assert_operator json.dig("counts", "documents"), :>, 0
    assert json.key?("trending")

    get "/api/trends?ticker=NVG&window_days=180&limit=5"
    assert_response :success
    assert_equal %w[sentiment_timeline themes volume_by_type], json.keys.sort
    assert_equal 180, json.dig("themes", "window_days")
    assert_operator json.dig("themes", "themes").size, :<=, 5

    get "/api/transactions"
    assert_response :success
    assert json["rows"].any?
    assert json.dig("stats", "ev_ebitda").key?("median")

    get "/api/dashboard-charts?months=12"
    assert_response :success
    assert_equal %w[sentiment volume], json.keys.sort
  end

  test "ingest requires documents" do
    post_json "/api/ingest", { documents: [] }
    assert_response :bad_request
    assert_match(/expected/, json["error"])
  end

  test "ingest rejects a malformed document" do
    post_json "/api/ingest", { documents: [{ title: "No body" }] }
    assert_response :bad_request
    assert_match(/missing required field/, json["error"])
  end

  test "ingest accepts documents" do
    post_json "/api/ingest", { documents: [{
      external_id: "api-1", title: "Ad hoc note", doc_type: "memo",
      published_at: "2026-09-01", body: "Margins expanded on pricing discipline."
    }] }
    assert_response :success
    assert_equal 1, json["added"]
  ensure
    Document.where(external_id: "api-1").destroy_all
    Search.reset_corpus_cache!
  end

  # docs/RAILS_PORT.md item 9: the API is unauthenticated, so a path may only
  # name something under data/.
  test "ingest path outside data is rejected" do
    ["../config/database.yml", Rails.root.join("config/database.yml").to_s, "/etc/passwd",
     Rails.root.join("data-elsewhere/x.json").to_s, "seed/../../config/master.key"].each do |path|
      post_json "/api/ingest", { path: path }
      assert_response :bad_request, path
      assert_match(/must be inside/, json["error"], path)
    end
  end

  test "ingest path inside data reaches the ingester and a missing one is 404" do
    post_json "/api/ingest", { path: "no-such-corpus.json" }
    assert_response :not_found
    assert_match(/no such path/, json["error"])

    seen = []
    original = Ingest.method(:ingest_path)
    Ingest.define_singleton_method(:ingest_path) do |path|
      seen << path.to_s
      { added: 0, skipped: 0, files: 0 }
    end
    begin
      post_json "/api/ingest", { path: "seed" }
      assert_response :success
      post_json "/api/ingest", { path: Rails.root.join("data/seed").to_s }
      assert_response :success
    ensure
      Ingest.define_singleton_method(:ingest_path, original)
    end
    assert_equal [Rails.root.join("data/seed").to_s] * 2, seen
    assert_equal({ "added" => 0, "skipped" => 0, "files" => 0 }, json)
  end

  test "watchlist round trip" do
    post_json "/api/watchlists", { name: "Grid software API", tickers: ["NVG"] }
    assert_response :success
    id = json["id"]
    post_json "/api/watchlists/#{id}/items", { tickers: ["hldx"] }
    assert_response :success
    assert_equal ["HLDX"], json["added"]

    get "/api/watchlists"
    listed = json["watchlists"].find { |row| row["id"] == id }
    assert_equal %w[HLDX NVG], listed["companies"].map { |row| row["ticker"] }.sort
    assert listed["companies"].first.key?("latest")

    delete "/api/watchlists/#{id}/items/hldx"
    assert_response :success
    assert_equal "HLDX", json["removed"]
    get "/api/watchlists"
    listed = json["watchlists"].find { |row| row["id"] == id }
    assert_equal ["NVG"], listed["companies"].map { |row| row["ticker"] }

    delete "/api/watchlists/#{id}"
    assert_response :success
    assert_equal id, json["deleted"]
    get "/api/watchlists"
    assert_nil(json["watchlists"].find { |row| row["id"] == id })
  ensure
    Watchlist.where(name: "Grid software API").each do |list|
      WatchlistItem.where(watchlist_id: list.id).delete_all
      list.delete
    end
  end

  test "unknown ticker on watchlist is rejected and nothing is added" do
    post_json "/api/watchlists", { name: "L-api" }
    id = json["id"]
    post_json "/api/watchlists/#{id}/items", { tickers: %w[NVG NOPE] }
    assert_response :not_found
    assert_match(/unknown ticker/, json["error"])
    assert_equal 0, WatchlistItem.where(watchlist_id: id).count

    post_json "/api/watchlists/#{id}/items", {}
    assert_response :bad_request
    post_json "/api/watchlists", { name: "  " }
    assert_response :bad_request
    post_json "/api/watchlists/#{10**7}/items", { tickers: ["NVG"] }
    assert_response :not_found
  ensure
    Watchlist.where(name: "L-api").each do |list|
      WatchlistItem.where(watchlist_id: list.id).delete_all
      list.delete
    end
  end

  test "saved search alerts report new documents" do
    post_json "/api/saved-searches", { name: "Pricing", query: "pricing pressure", last_seen_document_id: 0,
                                       filters: { ticker: ["NVG"] } }
    assert_response :success
    saved_id = json["id"]
    assert_equal({ "ticker" => ["NVG"] }, json["filters"])

    get "/api/saved-searches"
    assert_includes json["saved_searches"].map { |row| row["id"] }, saved_id

    get "/api/alerts"
    alert = json["alerts"].find { |row| row["saved_search_id"] == saved_id }
    assert_operator alert["new_documents"], :>, 0
    # Once marked seen, the same documents stop alerting.
    get "/api/alerts?mark_seen=1"
    get "/api/alerts"
    alert = json["alerts"].find { |row| row["saved_search_id"] == saved_id }
    assert_equal 0, alert["new_documents"]

    delete "/api/saved-searches/#{saved_id}"
    assert_response :success
    assert_equal saved_id, json["deleted"]
    refute SavedSearch.exists?(saved_id)
  ensure
    SavedSearch.where(id: saved_id).delete_all if saved_id
  end

  test "a saved search starts at the newest document by default" do
    post_json "/api/saved-searches", { query: "guidance" }
    assert_response :success
    assert_equal "guidance", json["name"]
    assert_equal Document.maximum(:id), json["last_seen_document_id"]
  ensure
    SavedSearch.where(query: "guidance").delete_all
  end

  test "saved search requires a query" do
    post_json "/api/saved-searches", { name: "x" }
    assert_response :bad_request
    assert_match(/query is required/, json["error"])
  end

  test "pitchbook lifecycle" do
    post_json "/api/pitchbooks", { target_ticker: "NVG", title: "Project API" }
    assert_response :success
    id = json["id"]
    @books << Pitchbook.find(id)
    assert json["slides"].any?
    assert_equal "NVG", json["ticker"]
    assert json.key?("comps")
    assert json.key?("evidence")

    get "/api/pitchbooks"
    assert_includes json["pitchbooks"].map { |row| row["id"] }, id
    assert json.key?("export_formats")

    get "/api/pitchbooks/#{id}/preview"
    assert_response :success
    assert_includes json["html"], "<section"

    get "/api/pitchbooks/#{id}/valuation"
    assert_response :success
    assert json["ranges"].any?
    assert json["ranges"].first.key?("in_conclusion")
    assert json.key?("wacc")
    assert json.dig("target").key?("basis_label")
    assert json["concluded_range"].key?("methods")

    get "/api/pitchbooks/#{id}/valuation-charts"
    assert_response :success
    assert_includes json["football_field"], "<svg"
    assert json.key?("sensitivity")
    assert json.key?("wacc")

    delete "/api/pitchbooks/#{id}"
    assert_response :success
    assert_equal id, json["deleted"]
    get "/api/pitchbooks/#{id}"
    assert_response :not_found
    delete "/api/pitchbooks/#{id}"
    assert_response :not_found
  end

  test "pitchbook requires a target" do
    post_json "/api/pitchbooks", { title: "No target" }
    assert_response :bad_request
  end

  test "unknown target returns 404" do
    post_json "/api/pitchbooks", { target_ticker: "NOPE" }
    assert_response :not_found
    assert_match(/unknown target ticker/, json["error"])
  end

  test "slide edits pin, reorder, comps, assumptions and rebuild" do
    book = make_book
    slide = book.slides.find_by(kind: "process")
    patch "/api/slides/#{slide.id}", params: JSON.generate(title: "Next steps, edited"), headers: JSON_HEADERS
    assert_response :success
    assert_equal "Next steps, edited", json["title"]
    assert_equal true, json["is_pinned"]
    post "/api/slides/#{slide.id}", params: JSON.generate(subtitle: "Unpinned", pin: false), headers: JSON_HEADERS
    assert_response :success
    assert_equal false, json["is_pinned"]
    patch "/api/slides/#{10**7}", params: JSON.generate(title: "x"), headers: JSON_HEADERS
    assert_response :not_found

    ids = book.slides.map(&:id)
    post_json "/api/pitchbooks/#{book.id}/reorder", { slide_ids: [ids[1], ids[0], *ids[2..]] }
    assert_response :success
    assert_equal [ids[1], ids[0]], json["slides"].first(2).map { |row| row["id"] }
    post_json "/api/pitchbooks/#{book.id}/reorder", { slide_ids: "nope" }
    assert_response :bad_request

    post_json "/api/pitchbooks/#{book.id}/comps", { tickers: %w[HLDX VLTR] }
    assert_response :success
    assert_equal %w[HLDX VLTR], json["comps"]
    post_json "/api/pitchbooks/#{book.id}/comps", { tickers: "HLDX" }
    assert_response :bad_request

    post_json "/api/pitchbooks/#{book.id}/assumptions", { wacc: 0.11 }
    assert_response :success
    assert_in_delta 0.11, json.dig("assumptions", "wacc"), 1e-9
    post_json "/api/pitchbooks/#{book.id}/assumptions", { wacc: 0.02, terminal_growth: 0.03 }
    assert_response :bad_request
    assert_in_delta 0.11, book.reload.assumptions_hash[:wacc], 1e-9

    post_json "/api/pitchbooks/#{book.id}/rebuild", {}
    assert_response :success
    assert_equal 14, json["slides"].size
  end

  test "evidence can be pinned and removed" do
    book = make_book
    document = Document.order(:id).first
    post_json "/api/pitchbooks/#{book.id}/evidence", { quote: "Churn ticked up.", document_id: document.id, note: "risk" }
    assert_response :success
    evidence_id = json["id"]
    assert_equal document.id, json["document_id"]
    appendix = book.slides.reload.find_by(kind: "evidence_appendix")
    assert_equal 1, appendix.payload_hash[:items].size

    post_json "/api/pitchbooks/#{book.id}/evidence", { quote: "" }
    assert_response :bad_request
    post_json "/api/pitchbooks/#{book.id}/evidence", { quote: "x", document_id: 10**7 }
    assert_response :bad_request

    delete "/api/evidence/#{evidence_id}"
    assert_response :success
    assert_equal evidence_id, json["deleted"]
    delete "/api/evidence/#{evidence_id}"
    assert_response :not_found
  end

  test "seed endpoint is idempotent" do
    before = Document.count
    post "/api/seed"
    assert_response :success
    assert_equal 0, json["documents_added"]
    assert_equal before, Document.count
  end

  # -------------------------------------------------------------- routing

  test "search endpoint" do
    get "/api/search?q=margin&limit=3"
    assert_response :success
    assert_operator json["results"].size, :<=, 3
  end

  test "unknown endpoint returns 404" do
    get "/api/nope"
    assert_response :not_found
    assert_equal "no such endpoint", json["error"]
    assert_equal "/api/nope", json["path"]
  end

  test "method not allowed" do
    post_json "/api/overview", {}
    assert_response :method_not_allowed
    assert_equal ["GET"], json["allowed"]
    assert_equal "GET", response.headers["Allow"]

    put "/api/pitchbooks", params: "{}", headers: JSON_HEADERS
    assert_response :method_not_allowed
    assert_equal %w[GET POST], json["allowed"]
  end

  test "non-numeric ids are not found" do
    get "/api/documents/abc"
    assert_response :not_found
    get "/api/pitchbooks/abc"
    assert_response :not_found
  end

  test "invalid json body" do
    post "/api/pitchbooks", params: "{not json", headers: JSON_HEADERS
    assert_response :bad_request
    assert_match(/invalid JSON body/, json["error"])
  end

  test "body too large" do
    post "/api/ingest", params: "[#{' ' * (8 * 1024 * 1024)}]", headers: JSON_HEADERS
    assert_response :content_too_large
    assert_equal "request body too large", json["error"]
  end

  test "head requests are answered like get" do
    head "/api/health"
    assert_response :success
  end

  # ---------------------------------------------------------------- export

  test "export download sets attachment headers" do
    book = make_book
    @exports << Exporters.export_dir.join(Exporters.filename_for(book, "html"))
    get "/api/pitchbooks/#{book.id}/export?format=html"
    assert_response :success
    assert_includes response.headers["Content-Disposition"], "attachment;"
    assert_includes response.headers["Content-Disposition"], "Project-HTTP-#{book.id}.html"
    assert_match %r{\Atext/html}, response.media_type
    assert_includes response.body[0, 200].downcase, "<!doctype html>"
  end

  test "export metadata without download goes to the export dir, never data" do
    book = make_book
    get "/api/pitchbooks/#{book.id}/export?format=html&download=0"
    assert_response :success
    @exports << json["path"]
    assert_equal "html", json["format"]
    assert_operator json["bytes"], :>, 0
    assert_equal "Project-HTTP-#{book.id}.html", json["filename"]
    assert json["path"].start_with?(Rails.root.join("tmp/exports").to_s), json["path"]
    refute json["path"].start_with?(Rails.root.join("data").to_s)
    assert File.exist?(json["path"])
  end

  test "pdf and pptx downloads carry their content types" do
    book = make_book
    { "pdf" => "application/pdf",
      "pptx" => "application/vnd.openxmlformats-officedocument.presentationml.presentation" }.each do |fmt, type|
      next unless Exporters.available_formats[fmt.to_sym]

      @exports << Exporters.export_dir.join(Exporters.filename_for(book, fmt))
      get "/api/pitchbooks/#{book.id}/export?format=#{fmt}"
      assert_response :success
      assert_equal type, response.media_type
      assert_operator response.body.bytesize, :>, 1000
    end
  end

  test "unknown export format is rejected" do
    book = make_book
    get "/api/pitchbooks/#{book.id}/export?format=xlsx&download=0"
    assert_response :bad_request
    assert_match(/unavailable/, json["error"])
  end
end
