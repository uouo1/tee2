# frozen_string_literal: true

require "test_helper"

# Port of tests/test_analytics.py, plus regression tests for the contract's
# deviations: the theme boilerplate stoplist (item 19), company-level KPI tiles
# with a period and a segment/table flag (item 20), and alerts that count every
# new matching document rather than the page of hits.
#
# Search is ported concurrently by another agent. The alert tests swap
# Search.search for a recording fake (see AlertStub) so they exercise this
# module's contract with Search and nothing else; if app/services/search.rb does
# not exist yet, a minimal Search module is defined so the fake has a home.
unless defined?(Search)
  module Search
    def self.search(_query = "", _filters = {}, **_opts)
      { total_documents: 0, returned: 0, results: [] }
    end
  end
end

module AlertStub
  # Replace Search.search for the duration of the block, restoring the original.
  def with_search(fake)
    original = Search.method(:search)
    # A block (not &fake) so the fake keeps the test as self.
    Search.define_singleton_method(:search) { |*args, **opts| fake.call(*args, **opts) }
    yield
  ensure
    Search.define_singleton_method(:search, original)
  end
end

class AnalyticsSeededTest < ActiveSupport::TestCase
  # Seed once and keep it: the demo corpus is deterministic and idempotent.
  self.use_transactional_tests = false

  setup do
    Seed::Demo.seed! unless Document.exists?
  end

  test "overview counts match the tables" do
    overview = Analytics.overview
    assert_equal Document.count, overview[:counts][:documents]
    assert_equal Document.count, overview[:by_type].sum { |row| row[:count] }
    assert_equal Chunk.count, overview[:counts][:chunks]
    assert_operator overview[:recent].size, :<=, 8
    assert_equal Document.count, overview[:sentiment][:distribution].sum { |row| row[:count] }
    assert_operator overview[:trending].size, :<=, 8
  end

  test "overview is anchored to the corpus not today" do
    assert_equal Document.maximum(:published_at), Analytics.overview[:as_of]
  end

  test "sentiment timeline is chronological" do
    timeline = Analytics.sentiment_timeline(ticker: "NVG")
    refute_empty timeline
    months = timeline.map { |row| row[:month] }
    assert_equal months.sort, months
    assert(timeline.all? { |row| row[:sentiment].between?(-1, 1) })
  end

  test "volume series align with the month axis" do
    volume = Analytics.volume_by_type
    refute_empty volume[:months]
    volume[:series].each do |series|
      assert_equal volume[:months].size, series[:values].size
    end
  end

  test "trending themes compare two windows" do
    trends = Analytics.trending_themes(window_days: 180)
    assert_operator trends[:recent_documents], :>, 0
    refute_empty trends[:themes]
    assert(trends[:themes].all? { |row| row[:lift].positive? })
    assert_equal Document.maximum(:published_at), trends[:as_of]
  end

  test "themes exclude speaker names" do
    # Themes come from chunk text, which has speaker attribution split off.
    themes = Analytics.trending_themes(window_days: 365)[:themes].map { |row| row[:theme] }
    refute(themes.any? { |theme| theme.include?("dana") || theme.include?("avery") })
  end

  test "seeded themes pass the boilerplate stoplist" do
    [Analytics.trending_themes(window_days: 365)[:themes],
     Analytics.company_profile("NVG")[:themes]].each do |themes|
      themes.each do |row|
        refute Analytics.boilerplate_theme?(row[:theme]), "boilerplate theme #{row[:theme].inspect}"
      end
    end
  end

  test "company themes exclude the company's own name" do
    themes = Analytics.company_profile("NVG")[:themes].map { |row| row[:theme] }
    refute_empty themes
    refute(themes.any? { |theme| (theme.split(" ") - %w[novagrid systems]).empty? })
  end

  test "company profile is complete" do
    profile = Analytics.company_profile("nvg")
    %i[financials market_data documents kpis sentiment_timeline themes metrics].each do |key|
      assert profile.key?(key), "missing #{key}"
    end
    assert_equal "NVG", profile[:ticker]
    assert_equal Document.joins(:company).where(companies: { ticker: "NVG" }).count, profile[:document_count]
    assert_includes %w[positive neutral negative], profile[:sentiment_label]
    assert_operator profile[:themes].size, :<=, 8
    # valuation_snapshot is Valuation.company_metrics as-is.
    assert profile[:metrics].key?(:basis_label)
  end

  test "unknown company" do
    assert_nil Analytics.company_profile("NOPE")
  end

  test "kpi series group by metric with history" do
    series = Analytics.kpi_series("NVG")
    refute_empty series
    series.each do |bucket|
      assert_equal bucket[:points].size, bucket[:observations]
      dates = bucket[:points].map { |point| point[:published_at] }
      assert_equal dates.sort, dates
      # Every tile carries its period, its label and whether it is company-level.
      assert bucket[:label].present?
      assert_kind_of Date, bucket[:period]
      assert_includes [true, false], bucket[:segment_or_table]
    end
    observations = series.map { |b| b[:observations] }
    assert_equal observations.sort.reverse, observations
  end
end

# Crafted fixtures inside a rolled-back transaction: whatever the seeded class
# left in the database, these documents are dated after it, so they set the
# as-of date for the test that creates them and vanish afterwards.
class AnalyticsDeviationTest < ActiveSupport::TestCase
  include AlertStub

  def future_date(offset = 0)
    (Document.maximum(:published_at) || Date.new(2026, 6, 30)) + 30 + offset
  end

  def add_doc(ticker, published_at, body, title: "Fixture")
    Ingest.ingest_document(title: title, doc_type: "transcript", published_at: published_at,
                           body: body, ticker: ticker, company_name: "Fixture #{ticker}")
  end

  test "themes drop filing boilerplate" do
    day = future_date
    4.times do |i|
      add_doc("ZZT", day - i, <<~TEXT)
        Net loss and comprehensive income adjustments were reported under the foreign currency rule provided by the standards.
        Utilities expanded interconnection queue backlogs across transmission planning programmes this spring.
        Management saw strong interconnection queue demand from hyperscale datacenter customers again.
      TEXT
    end
    themes = Analytics.trending_themes(window_days: 30, ticker: "ZZT")[:themes].map { |row| row[:theme] }
    refute_empty themes
    assert_includes themes, "interconnection queue"
    banned = %w[net loss comprehensive income adjustments foreign currency rule provided reported standards]
    themes.each do |theme|
      refute((theme.split(" ") & banned).any?, "boilerplate theme #{theme.inspect}")
    end
  end

  test "boilerplate predicate" do
    assert Analytics.boilerplate_theme?("loss net")
    assert Analytics.boilerplate_theme?("file rule")
    assert Analytics.boilerplate_theme?("table contents")
    assert Analytics.boilerplate_theme?("n/a")
    assert Analytics.boilerplate_theme?("pricing and/or")
    refute Analytics.boilerplate_theme?("interconnection queue")
    refute Analytics.boilerplate_theme?("datacenter")
  end

  def add_kpi(document, metric, value, context, unit: "%")
    Kpi.create!(document: document, company_id: document.company_id, metric: metric,
                value: value, unit: unit, context: context)
  end

  test "kpi latest prefers a company-level sentence over a newer segment row" do
    older = add_doc("ZZK", future_date(0), "Adjusted gross margin was 41.4% for the quarter, management said.")
    newer = add_doc("ZZK", future_date(5), "In the Device Solutions segment gross margin was 29.9% this quarter.")
    Kpi.where(document_id: [older.id, newer.id]).delete_all # only the rows below
    add_kpi(older, "gross_margin", 41.4, "Adjusted gross margin was 41.4% for the quarter, management said.")
    add_kpi(newer, "gross_margin", 29.9, "In the Device Solutions segment gross margin was 29.9% this quarter.")

    bucket = Analytics.kpi_series("ZZK").find { |b| b[:metric] == "gross_margin" }
    assert_equal 2, bucket[:observations]
    assert_equal "Gross margin", bucket[:label]
    assert_in_delta 41.4, bucket[:latest]
    assert_equal older.published_at, bucket[:period]
    assert_equal false, bucket[:segment_or_table]
    assert_equal "adjusted", bucket[:measure]
    assert_equal [false, true], bucket[:points].map { |p| p[:segment_or_table] }

    # It flows through company_profile unchanged.
    tile = Analytics.company_profile("ZZK")[:kpis].find { |b| b[:metric] == "gross_margin" }
    assert_in_delta 41.4, tile[:latest]
  end

  test "kpi latest skips a table row" do
    older = add_doc("ZZR", future_date(0), "Operating margin reached 18.2% on stronger pricing this year.")
    newer = add_doc("ZZR", future_date(3), "374.1 $ 325.9 Operating margin 9.0 % 10.6 %")
    Kpi.where(document_id: [older.id, newer.id]).delete_all
    add_kpi(older, "operating_margin", 18.2, "Operating margin reached 18.2% on stronger pricing this year.")
    add_kpi(newer, "operating_margin", 9.0, "374.1 $ 325.9 Operating margin 9.0 % 10.6 %")

    bucket = Analytics.kpi_series("ZZR").first
    assert_in_delta 18.2, bucket[:latest]
    assert_equal false, bucket[:segment_or_table]
    assert bucket[:points].last[:segment_or_table]
  end

  test "kpi falls back to the newest row and flags it when every row is segment-level" do
    older = add_doc("ZZS", future_date(0), "Networked Solutions gross margin was 33.0% in the period.")
    newer = add_doc("ZZS", future_date(2), "Outcomes segment gross margin was 35.5% in the period.")
    Kpi.where(document_id: [older.id, newer.id]).delete_all
    add_kpi(older, "gross_margin", 33.0, "Networked Solutions gross margin was 33.0% in the period.")
    add_kpi(newer, "gross_margin", 35.5, "Outcomes segment gross margin was 35.5% in the period.")

    bucket = Analytics.kpi_series("ZZS").first
    assert_in_delta 35.5, bucket[:latest]
    assert_equal newer.published_at, bucket[:period]
    assert_equal true, bucket[:segment_or_table]
  end

  def fake_hits(ids)
    ids.map { |id| { document_id: id, title: "Doc #{id}", chunk_id: id * 10 } }
  end

  test "alerts report the true number of new documents" do
    saved = SavedSearch.create!(name: "Queue", query: "interconnection queue",
                                filters: { ticker: "NVG" }.to_json, last_seen_document_id: 5)
    calls = []
    fake = lambda do |query = "", filters = {}, **opts|
      calls << [query, filters, opts]
      { total_documents: 14, returned: 10, results: fake_hits((6..15).to_a) }
    end
    with_search(fake) do
      alert = Analytics.check_alerts.find { |a| a[:saved_search_id] == saved.id }
      assert_equal 14, alert[:new_documents] # not min(limit, hits) = 10
      assert_equal 10, alert[:hits].size
      assert_equal "Queue", alert[:name]
      assert_equal "interconnection queue", alert[:query]
    end
    query, filters, opts = calls.find { |q, _, _| q == "interconnection queue" }
    assert_equal 5, filters[:min_document_id]
    assert_equal "NVG", filters[:ticker]
    assert_equal 10, opts[:limit]
    assert_equal false, opts[:summarize]
    assert_equal 5, saved.reload.last_seen_document_id # not marked without mark_seen
  end

  test "mark seen advances past every match, not just the first page" do
    saved = SavedSearch.create!(name: "All", query: "pricing", last_seen_document_id: 0)
    fake = ->(_q = "", _f = {}, **_o) { { total_documents: 3, returned: 3, results: fake_hits([2, 9, 4]) } }
    with_search(fake) { Analytics.check_alerts(mark_seen: true) }
    watermark = saved.reload.last_seen_document_id
    assert_operator watermark, :>=, 9
    assert_operator watermark, :>=, Document.maximum(:id).to_i
  end

  test "mark seen leaves the watermark alone when nothing is new" do
    saved = SavedSearch.create!(name: "None", query: "nothing", last_seen_document_id: 7)
    fake = ->(_q = "", _f = {}, **_o) { { total_documents: 0, returned: 0, results: [] } }
    with_search(fake) { Analytics.check_alerts(mark_seen: true) }
    assert_equal 7, saved.reload.last_seen_document_id
  end
end

# The empty-corpus tests delete everything inside the test's transaction, which
# is rolled back, so the seeded corpus survives for the other classes.
class AnalyticsEmptyCorpusTest < ActiveSupport::TestCase
  include AlertStub

  setup do
    [Evidence, Slide, CompMember, Pitchbook, Kpi, Chunk, Document, WatchlistItem, Watchlist,
     SavedSearch, MarketDatum, Financial, Company, Transaction].each(&:delete_all)
  end

  test "overview on an empty database" do
    overview = Analytics.overview
    assert_equal 0, overview[:counts][:documents]
    assert_equal [], overview[:by_type]
    assert_equal [], overview[:trending]
    # No documents: no as-of date and no tone, rather than today and 0.0.
    assert_nil overview[:as_of]
    assert_nil overview[:sentiment][:mean]
    assert_equal [], Analytics.sentiment_timeline
    assert_equal({ months: [], series: [] }, Analytics.volume_by_type)
  end

  test "alerts without saved searches" do
    assert_equal [], Analytics.check_alerts
  end

  test "a company without documents has no tone" do
    Company.create!(ticker: "ZZE", name: "Empty Co")
    profile = Analytics.company_profile("ZZE")
    assert_equal 0, profile[:document_count]
    assert_nil profile[:sentiment]
    assert_nil profile[:sentiment_label]
    assert_equal [], profile[:kpis]
    assert_equal [], profile[:themes]
    assert_equal({}, profile[:market_data])
  end
end
