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

  test "tags are chosen per period and filing, so a tag switch keeps every year" do
    facts = Marshal.load(Marshal.dump(FACTS))
    facts[:facts][:"us-gaap"][:Revenues] = { units: { USD: [
      # FY2023 was tagged Revenues; FY2024 moved to the contract-revenue tag.
      { start: "2023-01-01", end: "2023-12-31", val: 2_200_000_000, form: "10-K", fy: 2023, fp: "FY", filed: "2024-02-21", accn: "k23" },
      # The same FY2024 figure under the second tag must not duplicate the first tag's row.
      { start: "2024-01-01", end: "2024-12-31", val: 2_440_000_000, form: "10-K", fy: 2024, fp: "FY", filed: "2025-02-20", accn: "k24" }
    ] } }
    rows = Backtest::Fundamentals.observations(facts, cik: 1, ticker: "T")
    revenue = rows.select { |r| r[:concept] == "revenue" && r[:form] == "10-K" }.sort_by { |r| r[:period_end] }
    assert_equal [2023, 2024, 2024], revenue.map { |r| r[:period_end].year }
    assert_equal %w[Revenues RevenueFromContractWithCustomerExcludingAssessedTax RevenueFromContractWithCustomerExcludingAssessedTax], revenue.map { |r| r[:tag] }
    assert_equal 2_200_000_000.0, revenue.first[:value]
  end

  test "D&A is summed from depreciation and intangible amortisation when no combined tag covers a filing" do
    facts = { facts: { "us-gaap": {
      DepreciationDepletionAndAmortization: { units: { USD: [
        { start: "2023-01-01", end: "2023-12-31", val: 30_000_000, form: "10-K", fy: 2023, fp: "FY", filed: "2024-02-21", accn: "k23" }
      ] } },
      Depreciation: { units: { USD: [
        { start: "2023-01-01", end: "2023-12-31", val: 25_000_000, form: "10-K", fy: 2023, fp: "FY", filed: "2024-02-21", accn: "k23" },
        { start: "2024-01-01", end: "2024-12-31", val: 26_000_000, form: "10-K", fy: 2024, fp: "FY", filed: "2025-02-20", accn: "k24" }
      ] } },
      AmortizationOfIntangibleAssets: { units: { USD: [
        { start: "2024-01-01", end: "2024-12-31", val: 4_000_000, form: "10-K", fy: 2024, fp: "FY", filed: "2025-02-20", accn: "k24" },
        { start: "2025-01-01", end: "2025-12-31", val: 5_000_000, form: "10-K", fy: 2025, fp: "FY", filed: "2026-02-19", accn: "k25" }
      ] } }
    } } }
    rows = Backtest::Fundamentals.observations(facts, cik: 1).select { |r| r[:concept] == "dep_amort" }.sort_by { |r| r[:period_end] }
    assert_equal [[2023, 30_000_000.0, "DepreciationDepletionAndAmortization"], [2024, 30_000_000.0, "Depreciation+AmortizationOfIntangibleAssets"]],
                 rows.map { |r| [r[:period_end].year, r[:value], r[:tag]] }, "FY2025 has amortisation but no depreciation, so no row"
  end

  test "total debt is captured for filers that tag neither split line" do
    facts = { facts: { "us-gaap": { LongTermDebt: { units: { USD: [
      { end: "2024-12-31", val: 180_000_000_000, form: "10-K", fy: 2024, fp: "FY", filed: "2025-02-20", accn: "k24" }
    ] } } } } }
    rows = Backtest::Fundamentals.observations(facts, cik: 1)
    assert_equal [["debt_total", 180_000_000_000.0, "LongTermDebt"]], rows.map { |r| [r[:concept], r[:value], r[:tag]] }
    assert_includes PitFact::CONCEPTS, "debt_total"
  end

  test "members with no filing before mid-way through the following year are marked as non-filers" do
    UniverseMember.create!(cik: 21, ticker: "OLD", anchor_year: 2016)
    UniverseMember.create!(cik: 22, ticker: "NEW", anchor_year: 2016)
    UniverseMember.create!(cik: 23, ticker: nil, anchor_year: 2016, dropout_reason: "no_current_ticker")
    PitFact.create!(cik: 21, concept: "revenue", period_end: Date.new(2016, 12, 31), value: 1.0, filed: Date.new(2017, 2, 20), form: "10-K")
    PitFact.create!(cik: 22, concept: "revenue", period_end: Date.new(2016, 12, 31), value: 1.0, filed: Date.new(2019, 2, 20), form: "10-K")
    assert_equal 1, Backtest::Fundamentals.mark_non_filers!(2016)
    assert_nil UniverseMember.find_by(cik: 21).dropout_reason
    assert_equal "not_a_filer_in_anchor_year", UniverseMember.find_by(cik: 22).dropout_reason
    assert_equal "no_current_ticker", UniverseMember.find_by(cik: 23).dropout_reason, "an existing reason is kept"
  ensure
    PitFact.where(cik: [21, 22, 23]).delete_all
    UniverseMember.where(cik: [21, 22, 23]).delete_all
  end

  test "pit facts answer 'what was known on this date'" do
    rows = Backtest::Fundamentals.observations(FACTS, cik: 780571, ticker: "ITRI")
    PitFact.insert_all(rows, unique_by: %i[cik concept period_end filed])
    before = PitFact.known_on(780571, "revenue", Date.new(2025, 2, 19))
    assert_nil before, "the 10-K had not been filed yet"
    assert_nil PitFact.known_on(780571, "revenue", Date.new(2025, 2, 20)), "a filing dated t is public after t's close"
    refute_nil PitFact.known_on(780571, "revenue", Date.new(2025, 2, 21))
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
    history = lambda do |ticker, **_o|
      if ticker == "GOOD"
        { bars: Sources::PriceHistory.parse_yahoo(YAHOO, today: Date.new(2026, 11, 2)), splits: [{ date: Date.new(2026, 8, 14), ratio: 2.0 }] }
      else
        { bars: [], splits: [] }
      end
    end
    stubbing(Sources::PriceHistory, history: history) do
      totals = Backtest::Prices.build!(anchor_year: 2016)
      assert_equal 1, totals[:with_prices]
      assert_equal 1, totals[:no_price_history]
      assert_equal 2, totals[:bars]
      assert_equal 1, totals[:splits]
      assert_equal "no_price_history", UniverseMember.find_by(cik: 12).dropout_reason
      assert UniverseMember.find_by(cik: 11).has_prices
      assert_equal [[Date.new(2026, 8, 14), 2.0]], SplitEvent.where(ticker: "GOOD").pluck(:date, :ratio)
    end
  ensure
    PriceBar.where(ticker: %w[GOOD GONE]).delete_all
    SplitEvent.where(ticker: %w[GOOD GONE]).delete_all
    UniverseMember.where(cik: [11, 12]).delete_all
  end

  test "a dropout for another reason survives a successful price load" do
    UniverseMember.create!(cik: 13, ticker: "LATE", anchor_year: 2016, dropout_reason: "not_a_filer_in_anchor_year")
    history = ->(_ticker, **_o) { { bars: Sources::PriceHistory.parse_yahoo(YAHOO, today: Date.new(2026, 11, 2)), splits: [] } }
    stubbing(Sources::PriceHistory, history: history) do
      Backtest::Prices.build!(anchor_year: 2016)
      member = UniverseMember.find_by(cik: 13)
      assert member.has_prices
      assert_equal "not_a_filer_in_anchor_year", member.dropout_reason
    end
  ensure
    PriceBar.where(ticker: "LATE").delete_all
    UniverseMember.where(cik: 13).delete_all
  end

  test "ticker map keeps the first-listed ticker for a CIK, not the shortest" do
    index = {
      "0": { cik_str: 1166691, ticker: "CMCSA", title: "COMCAST CORP" },
      "1": { cik_str: 1166691, ticker: "CCZ", title: "COMCAST CORP" },
      "2": { cik_str: 1652044, ticker: "GOOGL", title: "Alphabet Inc." },
      "3": { cik_str: 1652044, ticker: "GOOG", title: "Alphabet Inc." }
    }
    stubbing(Sources::Http, fetch_json: ->(_url, **_o) { index }) do
      map = Backtest::Universe.ticker_map
      assert_equal "CMCSA", map[1166691]
      assert_equal "GOOGL", map[1652044]
    end
  end

  test "yahoo split events parse to dated ratios, oldest first" do
    payload = { chart: { result: [{
      timestamp: [], indicators: {},
      events: { splits: {
        "1717214400": { date: 1_718_026_200, numerator: 10.0, denominator: 1.0, splitRatio: "10:1" },
        "1625112000": { date: 1_626_787_800, numerator: 4.0, denominator: 1.0, splitRatio: "4:1" },
        "1500000000": { date: 1_500_000_000, numerator: 1.0, denominator: 8.0, splitRatio: "1:8" }
      } }
    }] } }
    splits = Sources::PriceHistory.parse_splits(payload)
    assert_equal [Date.new(2017, 7, 14), Date.new(2021, 7, 20), Date.new(2024, 6, 10)], splits.map { |s| s[:date] }
    assert_in_delta 0.125, splits[0][:ratio]
    assert_equal [4.0, 10.0], splits.last(2).map { |s| s[:ratio] }
    assert_equal [], Sources::PriceHistory.parse_splits(YAHOO), "no events key means no splits"
    assert_equal [], Sources::PriceHistory.parse_splits(nil)
  end
end
