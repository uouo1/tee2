# frozen_string_literal: true

require "test_helper"

# Offline tests for the backtest data acquisition (docs/BACKTEST.md). Every
# network call is stubbed; fixtures are the shapes the real endpoints return.
class BacktestAcquisitionTest < ActiveSupport::TestCase
  def stubbing(target, methods)
    singleton = target.singleton_class
    installed = []
    methods.each do |name, callable|
      singleton.send(:alias_method, :"__original_#{name}", name)
      installed << name
      singleton.send(:define_method, name) { |*args, **kwargs, &blk| callable.call(*args, **kwargs, &blk) }
    end
    yield
  ensure
    installed.each do |name|
      singleton.send(:alias_method, name, :"__original_#{name}")
      singleton.send(:remove_method, :"__original_#{name}")
    end
  end

  FRAME = {
    data: [
      { accn: "0001-16-1", cik: 1, entityName: "Alpha Corp", loc: "US-TX", start: "2016-01-01", end: "2016-12-31", val: 5_000_000_000 },
      { accn: "0001-16-2", cik: 2, entityName: "Beta Inc", loc: "US-NY", start: "2016-01-01", end: "2016-12-31", val: 3_000_000_000 },
      { accn: "0001-16-3", cik: 3, entityName: "Gamma Ltd", loc: "GB-LND", start: "2016-01-01", end: "2016-12-31", val: 9_000_000_000 },
      { accn: "0001-16-4", cik: 4, entityName: "Delta Co", loc: "US-CA", start: "2016-01-01", end: "2016-12-31", val: 1_000_000_000 }
    ]
  }.freeze
  TICKER_INDEX = { "0": { cik_str: 1, ticker: "ALPH", title: "Alpha Corp" }, "1": { cik_str: 2, ticker: "BETA", title: "Beta Inc" } }.freeze

  test "frames merge revenue tags, first tag wins per filer" do
    calls = []
    fetch_json = lambda do |url, **_opts|
      calls << url
      if url.include?("/Revenues/")
        { data: [{ cik: 7, entityName: "Seven", loc: "US-WA", val: 100, accn: "a" }] }
      else
        { data: [{ cik: 7, entityName: "Seven", loc: "US-WA", val: 999, accn: "b" }, { cik: 8, entityName: "Eight", loc: "US-WA", val: 50, accn: "c" }] }
      end
    end
    stubbing(Sources::Http, fetch_json: fetch_json) do
      merged = Sources::Frames.revenue_by_cik(2016, tags: %w[Revenues RevenueFromContractWithCustomerExcludingAssessedTax])
      assert_equal 100.0, merged[7][:val], "the first tag's value is kept"
      assert_equal 50.0, merged[8][:val]
      assert_equal 2, calls.size
    end
  end

  test "universe keeps US filers by revenue, counts those without a ticker" do
    fetch_json = lambda do |url, **_opts|
      case url
      when /frames/ then url.include?("/Revenues/") ? FRAME : { data: [] }
      when /company_tickers/ then TICKER_INDEX
      when /submissions/ then { sic: "3825", sicDescription: "Instruments", exchanges: ["Nasdaq"], name: "Alpha Corp" }
      else raise "unexpected #{url}"
      end
    end
    stubbing(Sources::Http, fetch_json: fetch_json) do
      summary = Backtest::Universe.build!(anchor_year: 2016, size: 3)
      assert_equal 3, summary[:members]
      assert_equal 2, summary[:with_ticker]
      assert_equal 1, summary[:no_current_ticker]
      refute UniverseMember.exists?(cik: 3), "non-US filer excluded"
      delta = UniverseMember.find_by(cik: 4)
      assert_equal "no_current_ticker", delta.dropout_reason
      assert_equal "3825", UniverseMember.find_by(cik: 1).sic
      assert_equal 3_000_000_000.0, summary[:median_revenue_anchor]
    end
  end

  FACTS = {
    facts: {
      dei: { EntityCommonStockSharesOutstanding: { units: { shares: [
        { end: "2025-02-10", val: 44_000_000, form: "10-K", fy: 2024, fp: "FY", filed: "2025-02-20", accn: "k24" },
        { end: "2025-07-24", val: 43_800_000, form: "10-Q", fy: 2025, fp: "Q2", filed: "2025-07-28", accn: "q2" }
      ] } } },
      "us-gaap": {
        RevenueFromContractWithCustomerExcludingAssessedTax: { units: { USD: [
          { start: "2024-01-01", end: "2024-12-31", val: 2_440_000_000, form: "10-K", fy: 2024, fp: "FY", filed: "2025-02-20", accn: "k24" },
          { start: "2024-01-01", end: "2024-12-31", val: 2_441_000_000, form: "10-K", fy: 2025, fp: "FY", filed: "2026-02-17", accn: "k25" },
          { start: "2024-10-01", end: "2024-12-31", val: 600_000_000, form: "10-K", fy: 2024, fp: "FY", filed: "2025-02-20", accn: "k24" },
          { start: "2025-04-01", end: "2025-06-30", val: 610_000_000, form: "10-Q", fy: 2025, fp: "Q2", filed: "2025-07-28", accn: "q2" },
          { start: "2025-01-01", end: "2025-06-30", val: 1_200_000_000, form: "10-Q", fy: 2025, fp: "Q2", filed: "2025-07-28", accn: "q2" },
          { start: "2024-01-01", end: "2024-12-31", val: 2_440_000_000, form: "8-K", fy: 2024, fp: "FY", filed: "2025-02-01", accn: "e" }
        ] } },
        OperatingIncomeLoss: { units: { USD: [
          { start: "2024-01-01", end: "2024-12-31", val: 264_000_000, form: "10-K", fy: 2024, fp: "FY", filed: "2025-02-20", accn: "k24" }
        ] } },
        CashAndCashEquivalentsAtCarryingValue: { units: { USD: [
          { end: "2024-12-31", val: 1_000_000_000, form: "10-K", fy: 2024, fp: "FY", filed: "2025-02-20", accn: "k24" },
          { end: "2024-12-31", val: 1_000_000_000, form: "10-K", fy: 2024, fp: "FY", filed: "2025-02-20", accn: "k24" }
        ] } }
      }
    }
  }.freeze

  test "fundamentals keep every filing of a value with its filed date, drop sub-year 10-K spans and YTD 10-Q spans" do
    rows = Backtest::Fundamentals.observations(FACTS, cik: 780571, ticker: "ITRI")
    revenue = rows.select { |r| r[:concept] == "revenue" }
    assert_equal 3, revenue.size, "two annual filings (original + restated) and one quarter"
    filed = revenue.select { |r| r[:form] == "10-K" }.map { |r| r[:filed] }.sort
    assert_equal [Date.new(2025, 2, 20), Date.new(2026, 2, 17)], filed
    assert_equal [Date.new(2025, 6, 30)], revenue.select { |r| r[:form] == "10-Q" }.map { |r| r[:period_end] }
    assert_equal 1, rows.count { |r| r[:concept] == "cash" }, "duplicate contexts collapse"
    assert_equal 2, rows.count { |r| r[:concept] == "shares_cover" }
    assert_equal "RevenueFromContractWithCustomerExcludingAssessedTax", revenue.first[:tag]
  end

  test "pit facts answer 'what was known on this date'" do
    rows = Backtest::Fundamentals.observations(FACTS, cik: 780571, ticker: "ITRI")
    PitFact.insert_all(rows, unique_by: %i[cik concept period_end filed])
    before = PitFact.known_on(780571, "revenue", Date.new(2025, 2, 19))
    assert_nil before, "the 10-K had not been filed yet"
    original = PitFact.known_on(780571, "revenue", Date.new(2025, 6, 1))
    assert_equal 2_440_000_000.0, original.value
    restated = PitFact.known_on(780571, "revenue", Date.new(2026, 3, 1))
    assert_equal 2_441_000_000.0, restated.value, "the restatement is visible once filed"
    assert_nil PitFact.known_on(780571, "revenue", Date.new(2026, 3, 1), period_end_after: Date.new(2025, 6, 30))
  ensure
    PitFact.where(cik: 780571).delete_all
  end

  YAHOO = {
    chart: { result: [{
      timestamp: [Time.utc(2026, 8, 1).to_i, Time.utc(2026, 9, 1).to_i, Time.utc(2026, 10, 1).to_i],
      indicators: { quote: [{ close: [100.0, nil, 110.0] }], adjclose: [{ adjclose: [99.0, nil, 110.0] }] }
    }] }
  }.freeze

  test "yahoo bars are labelled by month end, carry adjusted closes, and skip the running month" do
    bars = Sources::PriceHistory.parse_yahoo(YAHOO, today: Date.new(2026, 10, 14))
    assert_equal [Date.new(2026, 8, 31)], bars.map { |b| b[:month_end] }, "nil close dropped, October incomplete"
    assert_equal 99.0, bars.first[:adj_close]
    assert bars.first[:adjusted]
    assert_equal 2, Sources::PriceHistory.parse_yahoo(YAHOO, today: Date.new(2026, 11, 2)).size
  end

  test "nasdaq daily rows resample to the last trading day of each month, unadjusted" do
    payload = { data: { tradesTable: { rows: [
      { date: "08/29/2026", close: "$101.00" }, { date: "08/14/2026", close: "$95.00" }, { date: "07/31/2026", close: "$90.00" }
    ] } } }
    bars = Sources::PriceHistory.parse_nasdaq(payload, today: Date.new(2026, 10, 14))
    assert_equal [[Date.new(2026, 7, 31), 90.0], [Date.new(2026, 8, 31), 101.0]], bars.map { |b| [b[:month_end], b[:close]] }
    refute bars.first[:adjusted]
    assert_equal "nasdaq", bars.first[:source]
  end

  test "prices mark members without history as dropouts and count sources" do
    UniverseMember.create!(cik: 11, ticker: "GOOD", anchor_year: 2016)
    UniverseMember.create!(cik: 12, ticker: "GONE", anchor_year: 2016)
    bars = ->(ticker, **_o) { ticker == "GOOD" ? Sources::PriceHistory.parse_yahoo(YAHOO, today: Date.new(2026, 11, 2)) : [] }
    stubbing(Sources::PriceHistory, monthly_bars: bars) do
      totals = Backtest::Prices.build!(anchor_year: 2016)
      assert_equal 1, totals[:with_prices]
      assert_equal 1, totals[:no_price_history]
      assert_equal 2, totals[:bars]
      assert_equal "no_price_history", UniverseMember.find_by(cik: 12).dropout_reason
      assert UniverseMember.find_by(cik: 11).has_prices
    end
  ensure
    PriceBar.where(ticker: %w[GOOD GONE]).delete_all
    UniverseMember.where(cik: [11, 12]).delete_all
  end
end
