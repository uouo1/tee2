# frozen_string_literal: true

require "test_helper"
require "digest"
require "tmpdir"
require "zlib"

# Ingest is owned by another module of the port and may not have landed yet.
# This stand-in only exists so `Sources::Sec.load_company` can be exercised;
# every test that reaches it stubs `ingest_many` anyway.
unless defined?(Ingest)
  module Ingest
    def self.ingest_many(_docs)
      { added: 0, skipped: 0 }
    end
  end
end

# Port of tests/test_sources.py plus the pieces the contract adds: the Http
# fetcher's cache / throttle / backoff / 4xx rules, quote parsing, the
# diluted-vs-basic share split, EX-99.1 selection and the loader's writes.
#
# Everything runs against small hand-built fact structures and HTML fragments —
# no network — so the suite stays runnable in CI while still pinning down the
# XBRL selection rules that decide which numbers reach a pitch book.
class SourcesTest < ActiveSupport::TestCase
  FakeResponse = Struct.new(:code, :body, :headers) do
    def [](name)
      headers[name]
    end
  end

  # ------------------------------------------------------------- fixtures

  def fact(val, start, finish, form: "10-K", fp: "FY", filed: "2026-02-20")
    { val: val, start: start, end: finish, form: form, fp: fp, filed: filed }
  end

  def instant(val, finish, form: "10-K", fp: "FY", filed: "2026-02-20")
    { val: val, end: finish, form: form, fp: fp, filed: filed }
  end

  # Two fiscal years of a filer that tags revenue the modern way.
  def facts_fixture
    { facts: {
      dei: { EntityCommonStockSharesOutstanding: { units: { shares: [
        instant(40_000_000, "2025-12-31", filed: "2026-02-20"),
        instant(43_790_000, "2026-06-30", filed: "2026-08-01", form: "10-Q", fp: "Q2")
      ] } } },
      "us-gaap": {
        RevenueFromContractWithCustomerExcludingAssessedTax: { units: { USD: [
          fact(2_000e6, "2024-01-01", "2024-12-31", filed: "2025-02-20"),
          fact(2_400e6, "2025-01-01", "2025-12-31"),
          # A quarter must never be mistaken for a year.
          fact(600e6, "2025-10-01", "2025-12-31", form: "10-K", fp: "FY"),
          # A restatement filed later wins over the original.
          fact(2_010e6, "2024-01-01", "2024-12-31", filed: "2026-02-20")
        ] } },
        OperatingIncomeLoss: { units: { USD: [
          fact(200e6, "2024-01-01", "2024-12-31", filed: "2025-02-20"),
          fact(300e6, "2025-01-01", "2025-12-31")
        ] } },
        DepreciationDepletionAndAmortization: { units: { USD: [
          fact(50e6, "2024-01-01", "2024-12-31", filed: "2025-02-20"),
          fact(60e6, "2025-01-01", "2025-12-31")
        ] } },
        NetIncomeLoss: { units: { USD: [fact(150e6, "2025-01-01", "2025-12-31")] } },
        EarningsPerShareDiluted: { units: { "USD/shares": [fact(3.5, "2025-01-01", "2025-12-31")] } },
        PaymentsToAcquirePropertyPlantAndEquipment: { units: { USD: [fact(30e6, "2025-01-01", "2025-12-31")] } },
        IncomeLossFromContinuingOperationsBeforeIncomeTaxesExtraordinaryItemsNoncontrollingInterest: {
          units: { USD: [fact(250e6, "2025-01-01", "2025-12-31")] }
        },
        IncomeTaxExpenseBenefit: { units: { USD: [fact(50e6, "2025-01-01", "2025-12-31")] } },
        CashAndCashEquivalentsAtCarryingValue: { units: { USD: [instant(1_000e6, "2025-12-31")] } },
        LongTermDebtCurrent: { units: { USD: [instant(450e6, "2025-12-31")] } },
        LongTermDebtNoncurrent: { units: { USD: [instant(800e6, "2025-12-31")] } },
        AssetsCurrent: { units: { USD: [
          instant(1_500e6, "2024-12-31", filed: "2025-02-20"), instant(1_800e6, "2025-12-31")
        ] } },
        LiabilitiesCurrent: { units: { USD: [
          instant(900e6, "2024-12-31", filed: "2025-02-20"), instant(1_000e6, "2025-12-31")
        ] } }
      }
    } }
  end

  def gaap(facts)
    facts[:facts][:"us-gaap"]
  end

  def rows_by_year(facts, **opts)
    Sources::Sec.build_financials(facts, **opts).to_h { |row| [row[:fiscal_year], row] }
  end

  def submissions_fixture
    { name: "ITRON INC", tickers: ["ITRI"], sic: "3829", sicDescription: "Measuring & Controlling Devices",
      addresses: { business: { city: "LIBERTY LAKE", stateOrCountry: "WA", stateOrCountryDescription: "WA" } },
      filings: { recent: {
        form: ["10-K", "10-Q", "8-K", "4", "10-Q", "10-Q", "8-K", "8-K"],
        accessionNumber: ["0000780571-26-000010", "0000780571-26-000020", "0000780571-26-000030",
                          "0000780571-26-000031", "0000780571-25-000040", "0000780571-25-000050",
                          "0000780571-25-000060", "0000780571-25-000070"],
        filingDate: ["2026-02-20", "2026-04-30", "2026-04-28", "2026-04-27",
                     "2025-10-30", "2025-07-31", "2025-07-29", "2025-05-01"],
        reportDate: ["2025-12-31", "2026-03-31", "2026-04-28", "2026-04-27",
                     "2025-09-30", "2025-06-30", "2025-07-29", ""],
        primaryDocument: ["itri-20251231.htm", "itri-20260331.htm", "itri-8k.htm", "xslF345/form4.xml",
                          "itri-20250930.htm", "itri-20250630.htm", "itri-8k.htm", "itri-8k.htm"],
        primaryDocDescription: ["10-K", "10-Q", "8-K", "4", "10-Q", "10-Q", "8-K", "8-K"]
      } } }
  end

  def quote_fixture
    { ticker: "ITRI", share_price: 123.45, currency: "USD", week52_low: 80.1, week52_high: 130.9,
      as_of: Date.new(2026, 10, 9), exchange: "NasdaqGS" }
  end

  # Replace singleton methods on `target` with callables for the duration of
  # the block, then put the originals back. Minitest 6 no longer bundles
  # minitest/mock, so this is the sliver of `Object#stub` these tests need;
  # it is how nothing here reaches the network or the Ingest pipeline.
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

  # A paragraph long enough to clear collect_documents' minimum.
  def long_html(marker)
    "<html><body><p>#{marker}</p>" + Array.new(30) { |i| "<p>Paragraph #{i} of the filing discusses results.</p>" }.join + "</body></html>"
  end

  # ------------------------------------------------------- build_financials

  test "full year rows in millions" do
    by_year = rows_by_year(facts_fixture)
    assert_equal [2024, 2025], by_year.keys.sort
    assert_in_delta 2400.0, by_year[2025][:revenue]
    assert_in_delta 360.0, by_year[2025][:ebitda] # EBIT 300 + D&A 60
    assert_in_delta 300.0, by_year[2025][:ebit]
    assert_in_delta 3.5, by_year[2025][:eps]
    assert_in_delta 30.0, by_year[2025][:capex]
    assert_in_delta 0.2, by_year[2025][:tax_rate]
    assert_in_delta 150.0, by_year[2025][:net_income]
    assert_in_delta 60.0, by_year[2025][:dep_amort]
    assert_equal false, by_year[2025][:is_estimate]
  end

  test "rows carry exactly the financials columns" do
    row = Sources::Sec.build_financials(facts_fixture).first
    expected = %i[fiscal_year is_estimate revenue ebitda ebit net_income eps dep_amort capex nwc_change tax_rate]
    assert_equal expected, row.keys
  end

  test "quarter is not mistaken for a year" do
    rows = Sources::Sec.build_financials(facts_fixture)
    assert_not_includes rows.map { |row| row[:revenue] }, 600.0
  end

  test "later filing restates earlier year" do
    assert_in_delta 2010.0, rows_by_year(facts_fixture)[2024][:revenue]
  end

  test "working capital excludes cash and debt" do
    rows = rows_by_year(facts_fixture)
    # 2025: (1800 - 1000 cash) - (1000 - 450 debt) = 250; 2024: 1500 - 900 = 600
    assert_in_delta(-350.0, rows[2025][:nwc_change])
    assert_nil rows[2024][:nwc_change]
  end

  test "early January year end belongs to prior fiscal year" do
    assert_equal 2025, Sources::Sec.fiscal_year("2026-01-02")
    assert_equal 2025, Sources::Sec.fiscal_year("2025-12-31")
    assert_equal 2026, Sources::Sec.fiscal_year("2026-01-31")
  end

  test "separate depreciation and amortisation tags are summed" do
    facts = facts_fixture
    gaap(facts).delete(:DepreciationDepletionAndAmortization)
    gaap(facts)[:Depreciation] = { units: { USD: [fact(40e6, "2025-01-01", "2025-12-31")] } }
    gaap(facts)[:AmortizationOfIntangibleAssets] = { units: { USD: [fact(15e6, "2025-01-01", "2025-12-31")] } }
    rows = rows_by_year(facts)
    assert_in_delta 55.0, rows[2025][:dep_amort]
    assert_in_delta 355.0, rows[2025][:ebitda]
  end

  test "missing concepts become nil not zero" do
    facts = facts_fixture
    gaap(facts).delete(:DepreciationDepletionAndAmortization)
    rows = rows_by_year(facts)
    assert_nil rows[2025][:ebitda]
    assert_nil rows[2025][:dep_amort]
    assert_nil rows[2024][:net_income]
    assert_nil rows[2024][:eps]
    assert_nil rows[2024][:tax_rate]
  end

  test "tag preference falls back" do
    facts = facts_fixture
    gaap(facts)[:Revenues] = gaap(facts).delete(:RevenueFromContractWithCustomerExcludingAssessedTax)
    rows = Sources::Sec.build_financials(facts)
    assert_not_empty rows
    assert_in_delta 2400.0, rows.last[:revenue]
  end

  test "first tag with data wins even when a later one has more" do
    facts = facts_fixture
    gaap(facts)[:Revenues] = { units: { USD: [fact(9_999e6, "2025-01-01", "2025-12-31")] } }
    assert_in_delta 2400.0, rows_by_year(facts)[2025][:revenue]
  end

  test "years limit keeps newest" do
    rows = Sources::Sec.build_financials(facts_fixture, years: 1)
    assert_equal [2025], rows.map { |row| row[:fiscal_year] }
  end

  test "amended annual reports count and quarterly forms do not" do
    facts = facts_fixture
    gaap(facts)[:RevenueFromContractWithCustomerExcludingAssessedTax][:units][:USD] << fact(
      2_500e6, "2025-01-01", "2025-12-31", form: "10-K/A", filed: "2026-05-01"
    )
    gaap(facts)[:RevenueFromContractWithCustomerExcludingAssessedTax][:units][:USD] << fact(
      7_000e6, "2025-01-01", "2025-12-31", form: "10-Q", fp: "Q4", filed: "2026-06-01"
    )
    assert_in_delta 2500.0, rows_by_year(facts)[2025][:revenue]
  end

  # ---------------------------------------------------------- balance sheet

  test "net debt bridges debt and cash" do
    assert_in_delta 250.0, Sources::Sec.net_debt(facts_fixture, 2025) # 450 + 800 - 1000
  end

  test "net debt missing year" do
    assert_nil Sources::Sec.net_debt(facts_fixture, 2019)
  end

  test "net debt counts short-term investments as liquid" do
    facts = facts_fixture
    gaap(facts)[:ShortTermInvestments] = { units: { USD: [instant(100e6, "2025-12-31")] } }
    assert_in_delta 150.0, Sources::Sec.net_debt(facts, 2025)
  end

  test "cover shares uses latest period" do
    assert_in_delta 43_790_000, Sources::Sec.cover_shares(facts_fixture)
  end

  test "shares prefer the weighted diluted count and keep the cover page as basic" do
    facts = facts_fixture
    gaap(facts)[:WeightedAverageNumberOfDilutedSharesOutstanding] = { units: { shares: [
      fact(44_000_000, "2024-01-01", "2024-12-31", filed: "2025-02-20"),
      fact(46_320_000, "2025-01-01", "2025-12-31")
    ] } }
    shares = Sources::Sec.shares(facts)
    assert_in_delta 46_320_000, shares[:diluted] # latest fiscal year, not the largest
    assert_in_delta 43_790_000, shares[:basic]
  end

  test "diluted shares fall back to the cover page when no weighted count is tagged" do
    shares = Sources::Sec.shares(facts_fixture)
    assert_in_delta 43_790_000, shares[:diluted]
    assert_in_delta 43_790_000, shares[:basic]
  end

  test "shares fall back to weighted diluted for multi-class filers" do
    facts = facts_fixture
    facts[:facts][:dei] = {}
    gaap(facts)[:WeightedAverageNumberOfDilutedSharesOutstanding] = {
      units: { shares: [fact(33_000_000, "2025-01-01", "2025-12-31")] }
    }
    shares = Sources::Sec.shares(facts)
    assert_in_delta 33_000_000, shares[:diluted]
    assert_nil shares[:basic]
    gaap(facts).delete(:WeightedAverageNumberOfDilutedSharesOutstanding)
    assert_equal({ diluted: nil, basic: nil }, Sources::Sec.shares(facts))
  end

  # ---------------------------------------------------- document selection

  test "recent filings are rowised" do
    submissions = { filings: { recent: {
      form: ["10-K", "8-K"], accessionNumber: ["0001-25-1", "0001-25-2"],
      filingDate: ["2026-02-20", "2026-04-30"], reportDate: ["2025-12-31", "2026-04-29"],
      primaryDocument: ["a.htm", "b.htm"], primaryDocDescription: ["10-K", "8-K"]
    } } }
    rows = Sources::Sec.recent_filings(submissions)
    assert_equal ["10-K", "8-K"], rows.map { |row| row[:form] }
    assert_equal "0001-25-2", rows[1][:accessionNumber]
  end

  test "recent filings tolerate ragged columns" do
    rows = Sources::Sec.recent_filings({ filings: { recent: { form: ["8-K"], accessionNumber: [] } } })
    assert_equal 1, rows.size
    assert_nil rows[0][:accessionNumber]
    assert_equal [], Sources::Sec.recent_filings({})
  end

  test "form to doc type mapping" do
    assert_equal "filing", Sources::Sec::FORM_DOC_TYPES["10-K"]
    assert_equal "press-release", Sources::Sec::FORM_DOC_TYPES["8-K"]
  end

  test "exhibit url prefers an explicit 99.1 by normalised name" do
    index = { directory: { item: [
      { name: "0000780571-26-000030-index.htm" }, { name: "bmi-ex99_pressrelease.htm" },
      { name: "d12345dex991.htm" }, { name: "ex99-2.htm" }, { name: "ex991.jpg" }, { name: "R1.htm" }
    ] } }
    requested = nil
    stubbing(Sources::Http, fetch_json: ->(url, **_opts) { requested = url; index }) do
      url = Sources::Sec.exhibit_url("0000780571", "000078057126000030")
      assert_equal "https://www.sec.gov/Archives/edgar/data/780571/000078057126000030/d12345dex991.htm", url
    end
    assert_equal "https://www.sec.gov/Archives/edgar/data/780571/000078057126000030/index.json", requested
  end

  test "exhibit url falls back to any 99 exhibit and is nil without one" do
    stubbing(Sources::Http, fetch_json: ->(*) { { directory: { item: [{ name: "exh_992.htm" }, { name: "a.htm" }] } } }) do
      assert_match(/exh_992\.htm\z/, Sources::Sec.exhibit_url("780571", "000078057126000030"))
    end
    stubbing(Sources::Http, fetch_json: ->(*) { { directory: { item: [{ name: "a.htm" }] } } }) do
      assert_nil Sources::Sec.exhibit_url("780571", "000078057126000030")
    end
    stubbing(Sources::Http, fetch_json: ->(*) { raise Sources::Http::Error, "boom" }) do
      assert_nil Sources::Sec.exhibit_url("780571", "000078057126000030")
    end
  end

  test "collect documents respects per-form quotas, exhibits and minimum length" do
    # The 2026 8-K has an earnings release; the 2025-07 one has none; the
    # 2025-05 one is too short to be research material.
    indexes = {
      "000078057126000030" => { directory: { item: [{ name: "itri-ex991.htm" }] } },
      "000078057125000060" => { directory: { item: [{ name: "itri-8k.htm" }] } },
      "000078057125000070" => { directory: { item: [{ name: "ex99.htm" }] } }
    }
    fetched = []
    fetch_json = lambda do |url, **_opts|
      indexes.fetch(url[%r{/(\d{18})/index\.json\z}, 1])
    end
    fetch = lambda do |url, **_opts|
      fetched << url
      url.include?("000078057125000070") ? "<p>Short.</p>" : long_html(url)
    end
    docs = nil
    stubbing(Sources::Http, fetch_json: fetch_json, fetch: fetch) do
      docs = Sources::Sec.collect_documents("0000780571", submissions_fixture, annual: 1, quarterly: 2, press_releases: 4)
    end

    assert_equal %w[000078057126000010-10-K 000078057126000020-10-Q 000078057126000030-8-K 000078057125000040-10-Q],
                 docs.map { |doc| doc[:external_id] }
    annual = docs[0]
    assert_equal "Itron Inc Annual Report (10-K) — 2025-12-31", annual[:title]
    assert_equal "https://www.sec.gov/Archives/edgar/data/780571/000078057126000010/itri-20251231.htm", annual[:url]
    assert_equal "filing", annual[:doc_type]
    assert_equal "2026-02-20", annual[:published_at]
    assert_equal "2025-12-31", annual[:period]
    assert_equal "ITRI", annual[:ticker]
    assert_equal "Itron Inc", annual[:company_name]
    assert_equal "Itron Inc", annual[:author]
    assert_equal "SEC EDGAR", annual[:source]
    assert_operator annual[:body].length, :>=, 500
    assert_not_includes annual[:body], "<p>"

    release = docs[2]
    assert_equal "press-release", release[:doc_type]
    assert_equal "Itron Inc Earnings Release (8-K) — 2026-04-28", release[:title]
    assert_match(%r{/000078057126000030/itri-ex991\.htm\z}, release[:url])
    # The Form 4 was never fetched; the exhibit-less 8-K was never fetched.
    assert_not fetched.any? { |url| url.include?("form4") }
    assert_not fetched.any? { |url| url.include?("000078057125000060") }
  end

  test "collect documents skips a filing whose fetch fails" do
    fetch = ->(url, **_opts) { url.include?("20251231") ? raise(Sources::Http::Error, "503") : long_html(url) }
    docs = nil
    stubbing(Sources::Http, fetch_json: ->(*) { { directory: { item: [] } } }, fetch: fetch) do
      docs = Sources::Sec.collect_documents("780571", submissions_fixture, annual: 1, quarterly: 1, press_releases: 0)
    end
    assert_equal ["000078057126000020-10-Q"], docs.map { |doc| doc[:external_id] }
  end

  test "title case mirrors Python str.title" do
    assert_equal "Itron Inc", Sources::Sec.title_case("ITRON INC")
    assert_equal "O'Neil 3M Co", Sources::Sec.title_case("O'NEIL 3m co")
    assert_equal "Badger Meter Inc", Sources::Sec.title_case("badger meter inc")
  end

  # ------------------------------------------------------------- lookup

  test "resolve cik pads to ten digits" do
    index = { "0": { cik_str: 780_571, ticker: "ITRI", title: "Itron, Inc." },
              "1": { cik_str: 320_193, ticker: "AAPL", title: "Apple Inc." } }
    stubbing(Sources::Http, fetch_json: ->(*) { index }) do
      assert_equal "0000780571", Sources::Sec.resolve_cik("itri")
      assert_nil Sources::Sec.resolve_cik("NOPE")
    end
  end

  test "submissions and facts bypass the cache" do
    calls = []
    stubbing(Sources::Http, fetch_json: ->(url, **opts) { calls << [url, opts]; {} }) do
      Sources::Sec.fetch_submissions("0000780571")
      Sources::Sec.fetch_facts("0000780571")
    end
    assert_equal "https://data.sec.gov/submissions/CIK0000780571.json", calls[0][0]
    assert_equal "https://data.sec.gov/api/xbrl/companyfacts/CIK0000780571.json", calls[1][0]
    assert calls.all? { |(_, opts)| opts[:cache] == false }
  end

  # -------------------------------------------------------------- loader

  test "load company writes the company, financials and market data" do
    facts = facts_fixture
    gaap(facts)[:WeightedAverageNumberOfDilutedSharesOutstanding] = {
      units: { shares: [fact(46_320_000, "2025-01-01", "2025-12-31")] }
    }
    result = nil
    stubbing(Sources::Sec, resolve_cik: ->(_t) { "0000780571" }, fetch_submissions: ->(_c) { submissions_fixture },
                           fetch_facts: ->(_c) { facts }) do
      stubbing(Sources::Market, fetch_quote: ->(_t, **) { quote_fixture }) do
        result = Sources::Sec.load_company("itri", with_documents: false)
      end
    end

    company = Company.find_ticker("ITRI")
    assert_equal "Itron Inc", company.name
    assert_equal "Measuring & Controlling Devices", company.sector
    assert_equal "Measuring & Controlling Devices", company.industry
    assert_equal "LIBERTY LAKE, WA", company.hq # the address is stored as EDGAR reports it
    assert_equal "WA", company.country
    assert_equal "USD", company.currency
    assert_includes company.description, "CIK 780571"
    assert_includes company.description, "SIC 3829"

    assert_equal [2024, 2025], company.financials.order(:fiscal_year).pluck(:fiscal_year)
    assert_in_delta 2400.0, company.financials.find_by(fiscal_year: 2025).revenue
    assert_equal false, company.financials.first.is_estimate

    market = company.market_datum
    assert_in_delta 46.32, market.shares_diluted # weighted diluted, in millions
    assert_in_delta 43.79, market.shares_basic   # cover page
    assert_in_delta 250.0, market.net_debt
    assert_in_delta 123.45, market.share_price
    assert_in_delta 80.1, market.week52_low
    assert_in_delta 130.9, market.week52_high
    assert_equal Date.new(2026, 10, 9), market.as_of
    assert_nil market.beta

    assert_equal "ITRI", result[:ticker]
    assert_equal "Itron Inc", result[:name]
    assert_equal "0000780571", result[:cik]
    assert_equal [2024, 2025], result[:fiscal_years]
    assert_in_delta 2400.0, result[:latest_revenue]
    assert_in_delta 123.45, result[:share_price]
    assert_equal 0, result[:documents_added]
    assert_equal 0, result[:documents_skipped]
  end

  test "load company is idempotent and honours an explicit sector" do
    2.times do |run|
      stubbing(Sources::Sec, resolve_cik: ->(_t) { "0000780571" }, fetch_submissions: ->(_c) { submissions_fixture },
                             fetch_facts: ->(_c) { facts_fixture }) do
        stubbing(Sources::Market, fetch_quote: ->(_t, **) { quote_fixture }) do
          Sources::Sec.load_company("ITRI", sector: "Industrial Technology #{run}", with_documents: false)
        end
      end
    end
    assert_equal 1, Company.by_ticker("ITRI").count
    company = Company.find_ticker("ITRI")
    assert_equal "Industrial Technology 1", company.sector
    assert_equal 2, company.financials.count
    assert_equal 1, MarketDatum.where(company_id: company.id).count
    # No weighted diluted tag in the base fixture: diluted falls back to the cover page.
    assert_in_delta 43.79, company.market_datum.shares_diluted
    assert_in_delta 43.79, company.market_datum.shares_basic
  end

  test "load company skips market data without a quote or share count" do
    stubbing(Sources::Sec, resolve_cik: ->(_t) { "0000780571" }, fetch_submissions: ->(_c) { submissions_fixture },
                           fetch_facts: ->(_c) { facts_fixture }) do
      result = Sources::Sec.load_company("ITRI", with_documents: false, with_quote: false)
      assert_nil result[:share_price]
      assert_nil Company.find_ticker("ITRI").market_datum
    end
  end

  test "load company hands collected documents to Ingest" do
    documents = [{ external_id: "x-10-K", title: "T", doc_type: "filing", body: "b", published_at: "2026-02-20" }]
    received = nil
    result = nil
    stubbing(Sources::Sec, resolve_cik: ->(_t) { "0000780571" }, fetch_submissions: ->(_c) { submissions_fixture },
                           fetch_facts: ->(_c) { facts_fixture }, collect_documents: ->(*, **) { documents }) do
      stubbing(Ingest, ingest_many: ->(docs) { received = docs; { added: 1, skipped: 0 } }) do
        result = Sources::Sec.load_company("ITRI", with_quote: false)
      end
    end
    assert_equal documents, received
    assert_equal 1, result[:documents_added]
    assert_equal 0, result[:documents_skipped]
  end

  test "load company raises for an unknown ticker" do
    stubbing(Sources::Sec, resolve_cik: ->(_t) { nil }) do
      error = assert_raises(ArgumentError) { Sources::Sec.load_company("zzzz") }
      assert_includes error.message, "ZZZZ"
    end
  end

  test "load companies reports failures without sinking the batch" do
    loader = lambda do |ticker, **_opts|
      raise ArgumentError, "no SEC filer found for ticker #{ticker}" if ticker == "BAD"

      { ticker: ticker, documents_added: 3 }
    end
    stubbing(Sources::Sec, load_company: loader) do
      result = Sources::Sec.load_companies(%w[ITRI BAD BMI], with_documents: false)
      assert_equal 2, result[:companies]
      assert_equal 6, result[:documents_added]
      assert_equal [{ ticker: "BAD", error: "ArgumentError: no SEC filer found for ticker BAD" }], result[:failures]
    end
  end

  # ------------------------------------------------------- transactions csv

  test "csv round trip" do
    Dir.mktmpdir do |tmp|
      path = File.join(tmp, "deals.csv")
      File.write(
        path,
        "announced_on,target,acquirer,sector,ev,ev_revenue,ev_ebitda,premium_1day,consideration,note\n" \
        "2025-03-01,Target Co,Buyer Inc,Widgets,1500,3.2,14.5,0.28,Cash,Two-bidder process\n" \
        ",,missing,,,,,,,\n"
      )
      result = Sources::Sec.load_transactions_csv(path)
      assert_equal({ added: 1, rows: 2 }, result)
    end
    row = Transaction.find_by(target: "Target Co")
    assert_equal Date.new(2025, 3, 1), row.announced_on
    assert_equal "Buyer Inc", row.acquirer
    assert_equal "Widgets", row.sector
    assert_in_delta 1500.0, row.ev
    assert_in_delta 3.2, row.ev_revenue
    assert_in_delta 14.5, row.ev_ebitda
    assert_in_delta 0.28, row.premium_1day
    assert_equal "Cash", row.consideration
    assert_equal "Two-bidder process", row.note
  end

  test "csv blanks become nil and an undisclosed acquirer" do
    Dir.mktmpdir do |tmp|
      path = File.join(tmp, "deals.csv")
      File.write(path, "announced_on,target,acquirer,ev_ebitda\n2024-11-15T00:00:00,Quiet Co,, \n")
      Sources::Sec.load_transactions_csv(path)
    end
    row = Transaction.find_by(target: "Quiet Co")
    assert_equal "Undisclosed", row.acquirer
    assert_nil row.ev_ebitda
    assert_nil row.sector
    assert_equal Date.new(2024, 11, 15), row.announced_on
  end

  # ------------------------------------------------------------ html text

  test "strips tags scripts and hidden xbrl" do
    markup = <<~HTML
      <html><head><title>x</title><style>p{}</style></head><body>
      <div style="display:none">HIDDEN FACT COPY</div>
      <ix:header>hidden header</ix:header>
      <p>Revenue increased 12% to $2.4 billion.</p>
      <script>alert(1)</script>
      <p>Gross margin was 34.5%.</p>
      </body></html>
    HTML
    text = Sources::HtmlText.html_to_text(markup)
    assert_includes text, "Revenue increased 12%"
    assert_includes text, "Gross margin was 34.5%"
    assert_not_includes text, "HIDDEN"
    assert_not_includes text, "alert"
    assert_not_includes text, "<p>"
    # The <title> and <style> text are not content either.
    assert_equal "Revenue increased 12% to $2.4 billion.\n\nGross margin was 34.5%.", text
  end

  test "wrapped lines are rejoined into paragraphs" do
    text = Sources::HtmlText.html_to_text("<div>Revenue grew because</div><div>demand was strong.</div><div>Next item.</div>")
    assert_includes text, "Revenue grew because demand was strong."
    assert_includes text, "\n\nNext item."
  end

  test "page numbers are dropped" do
    text = Sources::HtmlText.html_to_text("<p>Item 1A.</p><p>42</p><p>Risk factors follow.</p>")
    assert_not_includes text, "\n42"
    assert_equal "Item 1A.\n\nRisk factors follow.", text
  end

  test "max chars cuts on a paragraph boundary" do
    markup = Array.new(200) { |i| "<p>Paragraph number #{i} with some words.</p>" }.join
    text = Sources::HtmlText.html_to_text(markup, max_chars: 800)
    assert_operator text.length, :<=, 800
    assert text.end_with?("."), "expected a paragraph boundary, got #{text[-20..].inspect}"
  end

  test "max chars falls back to a hard cut when no boundary fits" do
    text = Sources::HtmlText.html_to_text("<p>#{'word ' * 400}</p>", max_chars: 100)
    assert_equal 100, text.length
  end

  test "table of contents rows and headers are dropped" do
    markup = "<p>Table of Contents</p><p>Item 1A. Risk Factors 12</p><p>PART II</p>" \
             "<p>Table of Contents and revised tariffs apply.</p><p>Signatures 48</p>"
    text = Sources::HtmlText.html_to_text(markup)
    assert_not_includes text, "Table of Contents"
    assert_not_includes text, "Risk Factors 12"
    assert_not_includes text, "PART II"
    assert_includes text, "and revised tariffs apply."
  end

  test "zero width characters are removed" do
    text = Sources::HtmlText.html_to_text("<p>June​ 28,​ 2026 revenue﻿ grew</p>")
    assert_not_includes text, "​"
    assert_includes text, "June 28, 2026 revenue grew"
  end

  test "bytes input" do
    assert_includes Sources::HtmlText.html_to_text("<p>hello</p>".b), "hello"
    # Invalid UTF-8 is replaced, not raised, as bytes.decode(errors="replace") did.
    assert_includes Sources::HtmlText.html_to_text("<p>caf\xE9 au lait</p>".b), "au lait"
  end

  test "entities are unescaped once" do
    text = Sources::HtmlText.html_to_text(
      "<p>R&amp;D&nbsp;spend&#160;rose&#8217;&rsquo; &ldquo;a&rdquo; &mdash; &amp;nbsp; &lt;b&gt; &unknown;</p>"
    )
    assert_equal "R&D spend rose’’ “a” — &nbsp; <b> &unknown;", text
  end

  test "windows-1252 numeric references and invalid code points follow html.unescape" do
    text = Sources::HtmlText.html_to_text("<p>Itron&#146;s BlueEdge&#153; &#147;growth&#148;&#133; &#151; &#x97; &#8212;</p>")
    assert_equal "Itron’s BlueEdge™ “growth”… — — —", text
    text = Sources::HtmlText.html_to_text("<p>a&#0;b&#xD800;c&#1114112;d&#xFDD0;e&#xFFFE;f&#65;</p>")
    assert_equal "a�b�c�defA", text
    # Control-range references are dropped (a deck exported to HTML breaks
    # lines with &#11;), except the handful HTML5 keeps.
    text = Sources::HtmlText.html_to_text("<p>Investor&#11;Day&#1;&#14;&#31;&#127;x&#129;y&#13;z</p>")
    assert_equal "InvestorDayx\u0081y\rz", text
  end

  test "comments prologue and raw script text are not content" do
    markup = "<?xml version=\"1.0\"?><!DOCTYPE html><!-- hidden comment --><html><body>" \
             "<script type=\"text/javascript\">if (a < b) { document.write('</div><p>JS</p>'); }</script>" \
             "<p>Visible &lt; text</p><style>p > span { display: none }</style></body></html>"
    text = Sources::HtmlText.html_to_text(markup)
    assert_equal "Visible < text", text
  end

  test "quoted attribute values may contain a closing bracket" do
    text = Sources::HtmlText.html_to_text("<p style=\"font-family:'a>b'\">Kept.</p><p title='x>y'>Also kept.</p>")
    assert_equal "Kept.\n\nAlso kept.", text
  end

  test "display none with spaces and uppercase tags are handled" do
    markup = "<DIV STYLE=\"Display: None\">HIDDEN<div>nested</div></DIV><P>Shown.</P><BR/>Line two."
    text = Sources::HtmlText.html_to_text(markup)
    assert_not_includes text, "HIDDEN"
    assert_includes text, "Shown."
    assert_includes text, "Line two."
  end

  test "table cells become separate lines" do
    text = Sources::HtmlText.html_to_text("<table><tr><td>Revenue</td><td>2,400</td></tr><tr><td>EBITDA</td><td>1,360</td></tr></table>")
    assert_equal "Revenue\n\n2,400\n\nEBITDA\n\n1,360", text
    # A bare one-to-three digit cell is indistinguishable from a page number
    # and goes with it, as in the reference implementation.
    assert_equal "EBITDA", Sources::HtmlText.html_to_text("<table><tr><td>EBITDA</td><td>360</td></tr></table>")
  end

  test "stray angle brackets and truncated markup do not raise" do
    assert_equal "a < b and c > d", Sources::HtmlText.html_to_text("<p>a < b and c > d</p>")
    assert_equal "Cut", Sources::HtmlText.html_to_text("<p>Cut</p><div class=\"unterminated")
    assert_equal "", Sources::HtmlText.html_to_text("")
    assert_equal "Plain text, no tags.", Sources::HtmlText.html_to_text("Plain text, no tags.")
  end

  test "nbsp padding collapses to single spaces" do
    text = Sources::HtmlText.html_to_text("<p>Net  income was $150&nbsp;million.</p>")
    assert_equal "Net income was $150 million.", text
  end

  # ------------------------------------------------------------------ http

  def with_http_sandbox
    dir = Pathname.new(Dir.mktmpdir)
    Sources::Http.cache_dir = dir
    sleeps = []
    stubbing(Sources::Http, throttle: -> {}, sleep_for: ->(seconds) { sleeps << seconds }) do
      yield sleeps
    end
  ensure
    Sources::Http.cache_dir = nil
    FileUtils.remove_entry(dir) if dir&.exist?
  end

  test "cache path is the sha256 of the url under the cache dir" do
    with_http_sandbox do
      path = Sources::Http.cache_path("https://example.test/a")
      assert_equal Sources::Http.cache_dir, path.dirname
      assert_equal Digest::SHA256.hexdigest("https://example.test/a")[0, 32], path.basename.to_s
      assert_equal "#{path.basename}.json", Sources::Http.cache_path("https://example.test/a", ".json").basename.to_s
    end
  end

  test "fetch caches on disk and serves repeats without a request" do
    with_http_sandbox do
      calls = 0
      stubbing(Sources::Http, perform_request: ->(*) { calls += 1; FakeResponse.new("200", "hello", {}) }) do
        assert_equal "hello", Sources::Http.fetch("https://example.test/a")
        assert_equal "hello", Sources::Http.fetch("https://example.test/a")
        assert_equal "hello", Sources::Http.fetch("https://example.test/a", cache: false)
      end
      assert_equal 2, calls
      assert_equal "hello", File.read(Sources::Http.cache_path("https://example.test/a"))
      assert_not Sources::Http.cache_path("https://example.test/b").exist?
    end
  end

  test "fetch with cache false does not write the cache" do
    with_http_sandbox do
      stubbing(Sources::Http, perform_request: ->(*) { FakeResponse.new("200", "x", {}) }) do
        Sources::Http.fetch("https://example.test/nocache", cache: false)
      end
      assert_not Sources::Http.cache_path("https://example.test/nocache").exist?
    end
  end

  test "fetch sends the generic user agent and the caller's override" do
    with_http_sandbox do
      seen = []
      stubbing(Sources::Http, perform_request: ->(_uri, headers, _t) { seen << headers; FakeResponse.new("200", "x", {}) }) do
        Sources::Http.fetch("https://example.test/ua1", cache: false)
        Sources::Http.fetch("https://example.test/ua2", cache: false, user_agent: "Custom/1.0")
      end
      assert_equal Sources::Http::DEFAULT_USER_AGENT, seen[0]["User-Agent"]
      assert_equal "Custom/1.0", seen[1]["User-Agent"]
      assert_equal "gzip, deflate", seen[0]["Accept-Encoding"]
      assert_no_match(/@/, Sources::Http::DEFAULT_USER_AGENT) # never a personal address
    end
  end

  test "client errors raise immediately without retry" do
    with_http_sandbox do |sleeps|
      calls = 0
      stubbing(Sources::Http, perform_request: ->(*) { calls += 1; FakeResponse.new("404", "", {}) }) do
        error = assert_raises(Sources::Http::HttpError) { Sources::Http.fetch("https://example.test/missing") }
        assert_equal 404, error.status
      end
      assert_equal 1, calls
      assert_empty sleeps
      assert_not Sources::Http.cache_path("https://example.test/missing").exist?
    end
  end

  test "server errors back off exponentially then give up" do
    with_http_sandbox do |sleeps|
      calls = 0
      stubbing(Sources::Http, perform_request: ->(*) { calls += 1; FakeResponse.new("503", "", {}) }) do
        error = assert_raises(Sources::Http::Error) { Sources::Http.fetch("https://example.test/busy") }
        assert_match(/failed to fetch https:\/\/example.test\/busy: HTTP 503/, error.message)
      end
      assert_equal Sources::Http::MAX_ATTEMPTS, calls
      assert_equal [1, 2, 4], sleeps
    end
  end

  test "a transient network error is retried and the retry can succeed" do
    with_http_sandbox do |sleeps|
      calls = 0
      transport = lambda do |*|
        calls += 1
        raise Errno::ECONNRESET if calls == 1

        FakeResponse.new("200", "ok", {})
      end
      stubbing(Sources::Http, perform_request: transport) do
        assert_equal "ok", Sources::Http.fetch("https://example.test/flaky", cache: false)
      end
      assert_equal 2, calls
      assert_equal [1], sleeps
    end
  end

  test "gzip and mislabelled deflate bodies are decoded" do
    with_http_sandbox do
      bodies = {
        "/gz" => FakeResponse.new("200", Zlib.gzip("gzipped body"), { "Content-Encoding" => "gzip" }),
        "/zl" => FakeResponse.new("200", Zlib::Deflate.deflate("zlib body"), { "Content-Encoding" => "gzip" }),
        "/df" => FakeResponse.new("200", Zlib::Deflate.deflate("deflate body"), { "Content-Encoding" => "deflate" }),
        "/id" => FakeResponse.new("200", "plain body", {})
      }
      stubbing(Sources::Http, perform_request: ->(uri, *) { bodies.fetch(uri.path) }) do
        assert_equal "gzipped body", Sources::Http.fetch("https://example.test/gz", cache: false)
        assert_equal "zlib body", Sources::Http.fetch("https://example.test/zl", cache: false)
        assert_equal "deflate body", Sources::Http.fetch("https://example.test/df", cache: false)
        assert_equal "plain body", Sources::Http.fetch("https://example.test/id", cache: false)
      end
    end
  end

  test "redirects are followed" do
    with_http_sandbox do
      visited = []
      transport = lambda do |uri, *|
        visited << uri.to_s
        if uri.path == "/old"
          FakeResponse.new("301", "", { "Location" => "/new" })
        else
          FakeResponse.new("200", "moved here", {})
        end
      end
      stubbing(Sources::Http, perform_request: transport) do
        assert_equal "moved here", Sources::Http.fetch("https://example.test/old", cache: false)
      end
      assert_equal ["https://example.test/old", "https://example.test/new"], visited
    end
  end

  test "fetch json parses with symbol keys and tolerates bad bytes" do
    with_http_sandbox do
      body = "{\"facts\": {\"us-gaap\": {\"Revenues\": {\"units\": {\"USD/shares\": [1]}}}}, \"name\": \"caf\xE9\"}".b
      stubbing(Sources::Http, perform_request: ->(*) { FakeResponse.new("200", body, {}) }) do
        parsed = Sources::Http.fetch_json("https://example.test/j", cache: false)
        assert_equal [1], parsed.dig(:facts, :"us-gaap", :Revenues, :units, :"USD/shares")
        assert_equal "caf�", parsed[:name]
      end
    end
  end

  test "throttle spaces consecutive requests" do
    Sources::Http.throttle
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    Sources::Http.throttle
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    assert_operator elapsed, :>=, Sources::Http::MIN_INTERVAL_SECONDS - 0.02
  end

  # ---------------------------------------------------------------- market

  def chart_payload(meta_overrides = {}, closes: [100.0, nil, 90.0])
    meta = { symbol: "ITRI", regularMarketPrice: 123.456, currency: "USD", fiftyTwoWeekLow: 80.123,
             fiftyTwoWeekHigh: 130.987, regularMarketTime: 1_767_225_600, fullExchangeName: "NasdaqGS" }
    { chart: { result: [{ meta: meta.merge(meta_overrides), indicators: { quote: [{ close: closes }] } }] } }
  end

  test "fetch quote parses price range and date" do
    requested = nil
    stubbing(Sources::Http, fetch_json: ->(url, **opts) { requested = [url, opts]; chart_payload }) do
      quote = Sources::Market.fetch_quote("itri")
      assert_equal(
        { ticker: "ITRI", share_price: 123.46, currency: "USD", week52_low: 80.12, week52_high: 130.99,
          as_of: Date.new(2026, 1, 1), exchange: "NasdaqGS" },
        quote
      )
    end
    assert_equal "https://query1.finance.yahoo.com/v8/finance/chart/ITRI?range=1y&interval=1d", requested[0]
    assert_equal Sources::Market::QUOTE_USER_AGENT, requested[1][:user_agent]
    assert_equal true, requested[1][:cache]
  end

  test "fetch quote falls back to the year of closes for the range" do
    stubbing(Sources::Http, fetch_json: ->(*) { chart_payload({ fiftyTwoWeekLow: nil, fiftyTwoWeekHigh: 0 }) }) do
      quote = Sources::Market.fetch_quote("ITRI")
      assert_in_delta 90.0, quote[:week52_low]
      assert_in_delta 100.0, quote[:week52_high]
    end
    stubbing(Sources::Http, fetch_json: ->(*) { chart_payload({ fiftyTwoWeekLow: nil, fiftyTwoWeekHigh: nil, regularMarketTime: nil }, closes: []) }) do
      quote = Sources::Market.fetch_quote("ITRI")
      assert_nil quote[:week52_low]
      assert_nil quote[:week52_high]
      assert_nil quote[:as_of]
    end
  end

  test "fetch quote is nil without a price, a result or a reachable endpoint" do
    stubbing(Sources::Http, fetch_json: ->(*) { chart_payload({ regularMarketPrice: nil }) }) do
      assert_nil Sources::Market.fetch_quote("ITRI")
    end
    # Guard against the stub itself failing: a well-formed payload must parse.
    stubbing(Sources::Http, fetch_json: ->(*) { chart_payload }) do
      assert_not_nil Sources::Market.fetch_quote("ITRI")
    end
    stubbing(Sources::Http, fetch_json: ->(*) { { chart: { result: [] } } }) do
      assert_nil Sources::Market.fetch_quote("ITRI")
    end
    stubbing(Sources::Http, fetch_json: ->(*) { { chart: { result: nil, error: { code: "Not Found" } } } }) do
      assert_nil Sources::Market.fetch_quote("ITRI")
    end
    stubbing(Sources::Http, fetch_json: ->(*) { raise Sources::Http::HttpError.new(429, "x") }) do
      assert_nil Sources::Market.fetch_quote("ITRI")
    end
  end
end
