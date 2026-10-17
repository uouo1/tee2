# frozen_string_literal: true

require "test_helper"

# Port of tests/test_search.py, plus the contract additions (docs/RAILS_PORT.md
# items 5 and 21): document-level totals that do not depend on the page size,
# a sentiment facet that agrees with the sentiment filter, several values per
# field filter, and the date: field.

class SearchQueryParsingTest < ActiveSupport::TestCase
  test "phrases, terms and exclusions" do
    parsed = Search.parse_query('"interconnection queue" margin -restructuring type:filing')
    assert_equal ["interconnection queue"], parsed.phrases
    assert_equal ["margin"], parsed.terms
    assert_equal ["restructuring"], parsed.excluded
    assert_equal({ type: ["filing"] }, parsed.fields)
  end

  test "or groups" do
    parsed = Search.parse_query("tariff OR datacenter OR curtailment")
    assert_equal [%w[tariff datacenter curtailment]], parsed.or_groups
  end

  test "empty query" do
    assert Search.parse_query("").empty?
    assert Search.parse_query(nil).empty?
  end

  test "match expression expands synonyms" do
    expression = Search.build_match_expression(Search.parse_query("guidance"), expand: true)
    assert_includes expression, '"outlook"'
    plain = Search.build_match_expression(Search.parse_query("guidance"), expand: false)
    assert_equal '"guidance"', plain
  end

  test "match expression neutralises fts operators" do
    expression = Search.build_match_expression(Search.parse_query('"quote" mar*gin'), expand: false)
    refute_includes expression, "*"
    assert expression.count('"').even?
  end

  test "exclusions render as NOT" do
    expression = Search.build_match_expression(Search.parse_query("margin -churn"), expand: false)
    assert_includes expression, "NOT"
  end

  test "field filters keep every value" do
    parsed = Search.parse_query("ticker:ITRI ticker:BMI backlog")
    assert_equal({ ticker: %w[ITRI BMI] }, parsed.fields)
    assert_equal ["backlog"], parsed.terms
    assert_equal({ ticker: ["NVG"] }, Search.parse_query("ticker:NVG ticker:NVG").fields)
  end

  test "date field parses years, months, days and ranges" do
    assert_equal({ date: ["2026-07"] }, Search.parse_query("backlog date:2026-07").fields)
    assert_equal [Date.new(2026, 1, 1), Date.new(2026, 12, 31)], Search.parse_date_range("2026")
    assert_equal [Date.new(2026, 2, 1), Date.new(2026, 2, 28)], Search.parse_date_range("2026-02")
    assert_equal [Date.new(2026, 7, 15), Date.new(2026, 7, 15)], Search.parse_date_range("2026-07-15")
    assert_equal [Date.new(2026, 1, 1), Date.new(2026, 6, 30)], Search.parse_date_range("2026-01-01..2026-06-30")
    assert_equal [Date.new(2025, 1, 1), Date.new(2026, 3, 31)], Search.parse_date_range("2025..2026-03")
    assert_equal [Date.new(2026, 1, 1), nil], Search.parse_date_range("2026-01-01..")
    assert_nil Search.parse_date_range("yesterday")
    assert_nil Search.parse_date_range("2026-13")
  end

  test "highlight escapes then re-applies marks" do
    html = Search.highlight("<script>x</script> ⦑margin⦒\nnext")
    assert_equal "&lt;script&gt;x&lt;/script&gt; <mark>margin</mark> next", html
  end

  test "recency weighting prefers newer documents" do
    old = Search.recency_weight("2020-01-01", Date.new(2026, 10, 12))
    new = Search.recency_weight("2026-09-01", Date.new(2026, 10, 12))
    assert_operator new, :>, old
    assert_in_delta 0.8, Search.recency_weight("not a date", Date.new(2026, 10, 12))
  end
end

class SearchTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup { Seed::Demo.seed! unless Document.exists? }

  test "returns ranked results with snippets" do
    result = Search.search("pricing pressure", limit: 5)
    assert_operator result[:total_documents], :>, 0
    assert result[:results].all? { |row| row[:snippet_html].include?("<mark>") }
    scores = result[:results].map { |row| row[:score] }
    assert_equal scores.sort.reverse, scores
  end

  test "result rows carry the contract keys" do
    row = Search.search("revenue", limit: 1)[:results].first
    %i[chunk_id document_id seq speaker chunk_sentiment title doc_type source author published_at url
       doc_sentiment word_count ticker company sector score snippet_html sentiment_label match_count].each do |key|
      assert row.key?(key), "missing #{key}"
    end
    assert_kind_of Date, row[:published_at]
  end

  test "snippets are html escaped" do
    Search.search("revenue", limit: 5)[:results].each do |row|
      refute_includes row[:snippet_html].downcase, "<script"
    end
  end

  test "results are deduplicated per document" do
    result = Search.search("revenue", limit: 20)
    ids = result[:results].map { |row| row[:document_id] }
    assert_equal ids.uniq.size, ids.size
    assert result[:results].any? { |row| row[:match_count] >= 1 }
  end

  test "match count counts every matching passage of the document" do
    row = Search.search("revenue", limit: 1)[:results].first
    passages = ActiveRecord::Base.connection.select_value(
      ActiveRecord::Base.sanitize_sql_array([
        "SELECT COUNT(*) FROM chunks_fts f JOIN chunks ch ON ch.id = f.rowid WHERE chunks_fts MATCH ? AND ch.document_id = ?",
        Search.search("revenue", limit: 1)[:match_expression], row[:document_id]
      ])
    )
    assert_equal passages.to_i, row[:match_count]
  end

  test "each document is represented by its best passage" do
    result = Search.search("pricing pressure", limit: 3, summarize: false)
    result[:results].each do |row|
      best = ActiveRecord::Base.connection.select_value(
        ActiveRecord::Base.sanitize_sql_array([
          "SELECT ch.id FROM chunks_fts f JOIN chunks ch ON ch.id = f.rowid " \
          "WHERE chunks_fts MATCH ? AND ch.document_id = ? ORDER BY bm25(chunks_fts) LIMIT 1",
          result[:match_expression], row[:document_id]
        ])
      )
      assert_equal best.to_i, row[:chunk_id]
    end
  end

  test "filters narrow results" do
    filtered = Search.search("revenue", { doc_type: ["filing"] }, limit: 50)
    assert filtered[:results].any?
    assert filtered[:results].all? { |row| row[:doc_type] == "filing" }
  end

  test "inline field filter matches explicit filter" do
    inline = Search.search("revenue type:filing", limit: 50)
    explicit = Search.search("revenue", { doc_type: ["filing"] }, limit: 50)
    assert_equal explicit[:total_documents], inline[:total_documents]
  end

  test "exclusion removes documents" do
    with_term = Search.search("pressure", limit: 50)[:total_documents]
    without = Search.search("pressure -renewals", limit: 50)[:total_documents]
    assert_operator without, :<, with_term
  end

  test "empty query browses newest first" do
    result = Search.search("", limit: 5)
    dates = result[:results].map { |row| row[:published_at] }
    assert_equal dates.sort.reverse, dates
    assert result[:results].all? { |row| row[:score].zero? }
    # Browse totals are the whole filtered feed, not the page.
    assert_equal Document.joins(:chunks).distinct.count, result[:total_documents]
  end

  test "facets cover every dimension" do
    facets = Search.search("margin", limit: 5)[:facets]
    assert_equal %i[doc_type ticker sector year sentiment].sort, facets.keys.sort
    assert facets[:doc_type].all? { |row| row[:count].positive? }
  end

  test "summary bullets carry citations and are unique" do
    summary = Search.search("pricing pressure renewals", limit: 8)[:summary]
    assert summary[:bullets].any?
    texts = summary[:bullets].map { |bullet| bullet[:text] }
    assert_equal texts.uniq.size, texts.size
    assert summary[:bullets].all? { |bullet| bullet[:document_id] }
    assert summary[:themes].any?
    assert_includes %w[positive neutral negative], summary[:sentiment_label]
  end

  test "summary skips analyst questions" do
    result = Search.search("margin trajectory", limit: 10)
    summary = result.fetch(:summary, {})
    # In the seeded corpus every passage matching both words is an analyst's
    # question, so the right summary has no bullets at all.
    assert result[:results].any?
    assert result[:results].all? { |row| row[:speaker].to_s.include?("Analyst") }
    assert_equal [], summary[:bullets]
    summary.fetch(:bullets, []).each do |bullet|
      refute bullet[:text].rstrip.end_with?("?")
      assert_operator bullet[:text].split.size, :>=, 8
      assert_equal bullet[:text][0].upcase, bullet[:text][0]
    end
  end

  test "pagination" do
    first = Search.search("revenue", limit: 3, offset: 0)
    second = Search.search("revenue", limit: 3, offset: 3)
    refute_equal first[:results].map { |r| r[:document_id] }, second[:results].map { |r| r[:document_id] }
  end

  test "unknown term returns nothing without error" do
    result = Search.search("zzzznotaword", limit: 5)
    assert_equal 0, result[:total_documents]
    assert_equal [], result[:results]
    refute result.key?(:summary)
  end

  # --- contract additions (items 5 and 21) ---------------------------------

  test "total documents does not depend on page size" do
    small = Search.search("revenue OR margin OR growth", limit: 5)
    large = Search.search("revenue OR margin OR growth", limit: 50)
    assert_equal large[:total_documents], small[:total_documents]
    assert_operator small[:total_documents], :>, 50
    # Facet counts describe the same document set as the total.
    assert_equal small[:total_documents], small[:facets][:sentiment].sum { |row| row[:count] }
  end

  test "pages tile the full ranking without gaps or repeats" do
    query = "revenue OR margin"
    total = Search.search(query, limit: 200, summarize: false)[:total_documents]
    seen = []
    (0...total).step(40) do |offset|
      seen.concat(Search.search(query, limit: 40, offset: offset, summarize: false)[:results].map { |r| r[:document_id] })
    end
    assert_equal total, seen.size
    assert_equal total, seen.uniq.size
  end

  test "sentiment facet agrees with the sentiment filter" do
    result = Search.search("revenue OR margin OR pressure", limit: 5)
    facet = result[:facets][:sentiment].find { |row| row[:value] == "negative" }
    assert facet, "the seeded corpus has negative documents"
    filtered = Search.search("revenue OR margin OR pressure", { sentiment: "negative" }, limit: 200)
    assert_equal facet[:count], filtered[:total_documents]
    assert filtered[:results].all? { |row| row[:doc_sentiment] <= -0.18 }
    assert filtered[:results].all? { |row| row[:doc_sentiment_label] == "negative" }
  end

  test "two tickers in one query return documents of both" do
    tickers = Search.search("revenue", limit: 200)[:results].map { |row| row[:ticker] }.compact.uniq.first(2)
    assert_equal 2, tickers.size
    result = Search.search("revenue ticker:#{tickers[0]} ticker:#{tickers[1].downcase}", limit: 200)
    found = result[:results].map { |row| row[:ticker] }.uniq
    assert_equal tickers.sort, found.sort
    single = Search.search("revenue ticker:#{tickers[0]}", limit: 200)[:total_documents]
    assert_operator result[:total_documents], :>, single
  end

  test "date field narrows results" do
    everything = Search.search("revenue", limit: 200)
    year = everything[:results].map { |row| row[:published_at].year }.tally.max_by { |_, count| count }.first
    by_year = Search.search("revenue date:#{year}", limit: 200)
    assert_operator by_year[:total_documents], :>, 0
    assert_operator by_year[:total_documents], :<, everything[:total_documents]
    assert by_year[:results].all? { |row| row[:published_at].year == year }

    month = by_year[:results].first[:published_at]
    by_month = Search.search("revenue date:#{month.strftime('%Y-%m')}", limit: 200)
    assert_operator by_month[:total_documents], :<=, by_year[:total_documents]
    assert by_month[:results].all? { |row| row[:published_at].strftime("%Y-%m") == month.strftime("%Y-%m") }

    range = Search.search("revenue date:#{year}-01-01..#{year}-06-30", limit: 200)
    assert range[:results].all? { |row| row[:published_at].between?(Date.new(year, 1, 1), Date.new(year, 6, 30)) }
  end

  test "date field merges with date_from and date_to" do
    year = Search.search("revenue", limit: 1)[:results].first[:published_at].year
    merged = Search.search("revenue date:#{year}", { date_from: "#{year}-07-01" }, limit: 200)
    assert merged[:results].all? { |row| row[:published_at].between?(Date.new(year, 7, 1), Date.new(year, 12, 31)) }
    explicit = Search.search("revenue", { date_from: "#{year}-07-01", date_to: "#{year}-12-31" }, limit: 200)
    assert_equal explicit[:total_documents], merged[:total_documents]
  end

  test "browse mode honours filters and paginates on the true total" do
    ticker = Company.joins(:documents).pick(:ticker)
    result = Search.search("", { ticker: ticker }, limit: 2)
    assert_equal Document.joins(:company, :chunks).where(companies: { ticker: ticker }).distinct.count, result[:total_documents]
    assert result[:results].all? { |row| row[:ticker] == ticker }
    assert_equal result[:total_documents], result[:facets][:ticker].sum { |row| row[:count] }
  end

  test "limit is clamped" do
    assert_operator Search.search("revenue", limit: 10_000, summarize: false)[:returned], :<=, Search::MAX_RESULTS
    assert_operator Search.search("revenue", limit: 0, summarize: false)[:returned], :<=, 1
  end

  test "corpus stats are cached per document count" do
    first = Search.corpus_stats
    assert_same first, Search.corpus_stats
    assert_equal Document.count, first.doc_count
  end
end

class SearchDocumentTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup { Seed::Demo.seed! unless Document.exists? }

  test "document view is complete" do
    document_id = Search.search("revenue", limit: 1)[:results].first[:document_id]
    document = Search.get_document(document_id)
    %i[chunks kpis summary keywords similar sentiment_label].each { |key| assert document.key?(key), key.to_s }
    assert document[:chunks].any?
    assert document[:chunks].all? { |chunk| chunk.key?(:sentiment_label) }
  end

  test "missing document" do
    assert_nil Search.get_document(10**7)
  end

  test "similar documents are ranked and exclude self" do
    document_id = Search.search("revenue", limit: 1)[:results].first[:document_id]
    similar = Search.similar_documents(document_id, limit: 5)
    assert similar.any?
    refute_includes similar.map { |row| row[:document_id] }, document_id
    scores = similar.map { |row| row[:similarity] }
    assert_equal scores.sort.reverse, scores
  end
end
