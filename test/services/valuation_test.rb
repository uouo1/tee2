# frozen_string_literal: true

require "test_helper"

# Port of tests/test_valuation.py, plus coverage for what the contract adds
# (DcfAssumptions coercion, the precedent-less football field, the ±100/±50bps
# DCF band, the median concluded range, the NWC/tax clamps).
#
# Seed::Demo does not exist yet, so the company universe is built here from the
# same COMPANIES and TRANSACTIONS tables as argos/seed.py, with prices derived
# the way `_derive_market` does (off a target EV/EBITDA multiple) and the
# financial series back-cast the way `_financial_series` does. The 52-week band
# uses the mid-points of the seed's uniform draws instead of the RNG.
module ValuationSeed
  SECTOR = "Grid & Energy Software"
  YEARS = [2023, 2024, 2025, 2026, 2027, 2028].freeze

  COMPANIES = [
    { ticker: "NVG", name: "NovaGrid Systems", industry: "Grid orchestration software",
      country: "United States", hq: "Austin, TX", employees: 4280,
      fin: { revenue: 1840.0, growth: 0.168, ebitda_margin: 0.262, da_pct: 0.052, capex_pct: 0.041,
             shares: 182.0, net_debt: 410.0, ev_ebitda_target: 17.5, beta: 1.21 } },
    { ticker: "HLDX", name: "Helio Dynamics", industry: "DER management software",
      country: "United States", hq: "San Jose, CA", employees: 3110,
      fin: { revenue: 1320.0, growth: 0.142, ebitda_margin: 0.238, da_pct: 0.049, capex_pct: 0.038,
             shares: 141.0, net_debt: 260.0, ev_ebitda_target: 16.0, beta: 1.14 } },
    { ticker: "VLTR", name: "Voltara Networks", industry: "Grid telemetry & analytics",
      country: "United States", hq: "Denver, CO", employees: 5640,
      fin: { revenue: 2410.0, growth: 0.096, ebitda_margin: 0.281, da_pct: 0.061, capex_pct: 0.058,
             shares: 238.0, net_debt: 980.0, ev_ebitda_target: 14.5, beta: 1.02 } },
    { ticker: "CRGD", name: "Cerulean Grid", industry: "Market settlement software",
      country: "United Kingdom", hq: "London, UK", employees: 1980,
      fin: { revenue: 860.0, growth: 0.201, ebitda_margin: 0.221, da_pct: 0.044, capex_pct: 0.036,
             shares: 96.0, net_debt: 95.0, ev_ebitda_target: 18.5, beta: 1.33 } },
    { ticker: "PYLN", name: "Pylon Analytics", industry: "Transmission planning software",
      country: "United States", hq: "Pittsburgh, PA", employees: 1240,
      fin: { revenue: 520.0, growth: 0.247, ebitda_margin: 0.184, da_pct: 0.040, capex_pct: 0.033,
             shares: 71.0, net_debt: -60.0, ev_ebitda_target: 20.0, beta: 1.42 } },
    { ticker: "TWSW", name: "Terrawatt Software", industry: "Renewables asset management",
      country: "Germany", hq: "Munich, DE", employees: 2870,
      fin: { revenue: 1150.0, growth: 0.071, ebitda_margin: 0.196, da_pct: 0.055, capex_pct: 0.047,
             shares: 128.0, net_debt: 520.0, ev_ebitda_target: 11.5, beta: 1.09 } },
    { ticker: "MFCL", name: "Meridian Flow Controls", industry: "Industrial control software",
      country: "United States", hq: "Milwaukee, WI", employees: 7320,
      fin: { revenue: 3080.0, growth: 0.034, ebitda_margin: 0.173, da_pct: 0.068, capex_pct: 0.062,
             shares: 311.0, net_debt: 1640.0, ev_ebitda_target: 9.0, beta: 0.91 } }
  ].freeze

  TRANSACTIONS = [
    { announced_on: "2026-06-18", target: "Arclight Grid Software", acquirer: "Siemens-adjacent strategic",
      sector: SECTOR, ev: 4100.0, ev_revenue: 6.4, ev_ebitda: 22.8, premium_1day: 0.31, consideration: "Cash",
      note: "Full-cash take-private of a subscription-heavy grid planning vendor." },
    { announced_on: "2026-02-04", target: "Keystone DERMS", acquirer: "Thoma-style sponsor",
      sector: SECTOR, ev: 2250.0, ev_revenue: 5.1, ev_ebitda: 19.4, premium_1day: 0.27, consideration: "Cash",
      note: "Sponsor LBO; carve-out of services backlog pre-close." },
    { announced_on: "2025-11-12", target: "Lumen Flow Systems", acquirer: "Strategic acquirer (industrial)",
      sector: SECTOR, ev: 1480.0, ev_revenue: 4.2, ev_ebitda: 16.1, premium_1day: 0.22, consideration: "Cash and stock",
      note: "Hardware-weighted mix drove a lower multiple." },
    { announced_on: "2025-07-29", target: "Meridian Analytics (division)", acquirer: "Private equity consortium",
      sector: SECTOR, ev: 910.0, ev_revenue: 3.6, ev_ebitda: 14.2, premium_1day: 0.18, consideration: "Cash",
      note: "Divisional carve-out with TSA; limited competitive tension." },
    { announced_on: "2025-03-20", target: "Quanta Settlement Co", acquirer: "Exchange operator",
      sector: SECTOR, ev: 3350.0, ev_revenue: 7.1, ev_ebitda: 24.6, premium_1day: 0.38, consideration: "Stock",
      note: "Scarcity premium for regulated settlement infrastructure." },
    { announced_on: "2024-10-08", target: "Northwind Interconnect", acquirer: "Strategic acquirer (software)",
      sector: SECTOR, ev: 1720.0, ev_revenue: 5.6, ev_ebitda: 20.1, premium_1day: 0.29, consideration: "Cash",
      note: "Two-bidder process; synergies underwritten at 7% of target revenue." }
  ].freeze

  module_function

  def seed!(transactions: true)
    COMPANIES.each do |spec|
      company = Company.create!(
        spec.except(:fin).merge(sector: SECTOR, currency: "USD", description: "#{spec[:name]} (demo).")
      )
      financial_series(spec[:fin]).each { |row| company.financials.create!(row) }
      market = derive_market(spec[:fin])
      MarketDatum.create!(
        company: company, as_of: Date.new(2026, 10, 9), share_price: market[:price],
        shares_diluted: spec[:fin][:shares], net_debt: spec[:fin][:net_debt],
        week52_low: market[:low], week52_high: market[:high], beta: spec[:fin][:beta]
      )
    end
    TRANSACTIONS.each { |deal| Transaction.create!(deal) } if transactions
  end

  # seed.py `_derive_market`: price off the target multiple so implied comps
  # land where the quality spread says they should.
  def derive_market(fin)
    ebitda = fin[:revenue] * fin[:ebitda_margin]
    enterprise_value = fin[:ev_ebitda_target] * ebitda
    price = [1.0, (enterprise_value - fin[:net_debt]) / fin[:shares]].max
    { price: price.round(2), low: (price * 0.73).round(2), high: (price * 1.11).round(2) }
  end

  # seed.py `_financial_series`: back-cast and forecast around the base year.
  def financial_series(fin)
    base_year = YEARS[YEARS.size / 2]
    YEARS.map do |year|
      drift = fin[:growth] * (year > base_year ? 0.82 : 1.0)
      factor = (1 + drift)**(year - base_year)
      revenue = fin[:revenue] * factor
      margin = fin[:ebitda_margin] + 0.004 * (year - base_year)
      ebitda = revenue * margin
      dep_amort = revenue * fin[:da_pct]
      ebit = ebitda - dep_amort
      tax_rate = 0.23
      net_income = [0.0, ebit * (1 - tax_rate)].max - [0.0, fin[:net_debt]].max * 0.045 * (1 - tax_rate)
      {
        fiscal_year: year, is_estimate: year > base_year,
        revenue: revenue.round(1), ebitda: ebitda.round(1), ebit: ebit.round(1),
        net_income: net_income.round(1), eps: (net_income / fin[:shares]).round(2),
        dep_amort: dep_amort.round(1), capex: (revenue * fin[:capex_pct]).round(1),
        nwc_change: (revenue * 0.012).round(1), tax_rate: tax_rate
      }
    end
  end
end

class ValuationStatisticsTest < ActiveSupport::TestCase
  test "percentile interpolates" do
    values = [1, 2, 3, 4]
    assert_equal 1, Valuation.percentile(values, 0)
    assert_equal 4, Valuation.percentile(values, 1)
    assert_in_delta 2.5, Valuation.percentile(values, 0.5), 1e-9
  end

  test "percentile handles empty and single" do
    assert_nil Valuation.percentile([], 0.5)
    assert_equal 7.0, Valuation.percentile([7], 0.9)
  end

  test "percentile ignores nils and clamps pct" do
    assert_in_delta 3.0, Valuation.percentile([nil, 3, nil, 1], 1.7), 1e-9
    assert_in_delta 1.0, Valuation.percentile([3, 1], -0.2), 1e-9
  end

  test "describe ignores missing values" do
    stats = Valuation.describe([1, nil, 3])
    assert_equal 2, stats[:count]
    assert_equal 1, stats[:min]
    assert_equal 3, stats[:max]
    assert_in_delta 2.0, stats[:mean], 1e-9
  end

  test "mean is compensated like the reference's sum()" do
    # CPython >= 3.12 sums floats with Neumaier compensation; a naive
    # left-to-right sum would report 0.09999999999999999 and 0.0 here.
    assert_equal 0.1, Valuation.describe([0.1] * 10)[:mean]
    assert_equal 1.0 / 3, Valuation.describe([1e16, 1.0, -1e16])[:mean]
  end

  test "describe of nothing is all nils with a zero count" do
    assert_equal({ count: 0, min: nil, p25: nil, median: nil, p75: nil, max: nil, mean: nil },
                 Valuation.describe([nil]))
  end

  test "constants" do
    assert_equal %i[ev_revenue ev_ebitda pe], Valuation::MULTIPLES
    assert_equal "EV / EBITDA", Valuation::MULTIPLE_LABELS[:ev_ebitda]
  end
end

class ValuationCompanyMetricsTest < ActiveSupport::TestCase
  setup { ValuationSeed.seed! }

  test "enterprise value bridge" do
    metrics = Valuation.company_metrics("NVG")
    assert_in_delta metrics[:share_price] * metrics[:shares_diluted], metrics[:market_cap], 0.05
    assert_in_delta metrics[:market_cap] + metrics[:net_debt], metrics[:enterprise_value], 0.05
  end

  test "multiples use the latest actual year" do
    metrics = Valuation.company_metrics("NVG")
    latest = metrics[:latest_actual]
    assert_equal false, latest[:is_estimate]
    assert_equal 2026, latest[:fiscal_year]
    assert_in_delta metrics[:enterprise_value] / latest[:ebitda], latest[:ev_ebitda], 0.05
  end

  test "forward years are estimates" do
    metrics = Valuation.company_metrics("NVG")
    assert_equal 2, metrics[:forward].size
    assert metrics[:forward].all? { |row| row[:is_estimate] }
    assert_equal [2027], Valuation.company_metrics("NVG", forward_years: 1)[:forward].map { |r| r[:fiscal_year] }
  end

  test "unknown ticker" do
    assert_nil Valuation.company_metrics("NOPE")
  end

  test "ticker is case insensitive" do
    assert_not_nil Valuation.company_metrics("nvg")
  end

  test "values match the reference implementation for the demo target" do
    metrics = Valuation.company_metrics("NVG")
    assert_equal 44.1, metrics[:share_price]
    assert_equal 8026.2, metrics[:market_cap]
    assert_equal 8436.2, metrics[:enterprise_value]
    assert_equal 17.5, metrics[:latest_actual][:ev_ebitda]
    assert_equal 4.58, metrics[:latest_actual][:ev_revenue]
    assert_equal 28.27, metrics[:latest_actual][:pe]
    assert_equal 0.262, metrics[:latest_actual][:ebitda_margin]
    assert_equal Date.new(2026, 10, 9), metrics[:as_of]
    assert_equal "USD", metrics[:currency]
  end

  test "the share-count basis is exposed so views can label it" do
    # The demo set loads no cover-page count; a filer that reports both keeps
    # them distinct, and one with no diluted count stores the same number twice.
    assert_nil Valuation.company_metrics("NVG")[:shares_basic]
    Company.find_ticker("NVG").market_datum.update!(shares_basic: 175.5)
    metrics = Valuation.company_metrics("NVG")
    assert_equal [182.0, 175.5], [metrics[:shares_diluted], metrics[:shares_basic]]
    row = Valuation.comps_table(%w[NVG])[:rows].first
    assert_equal [182.0, 175.5], [row[:shares_diluted], row[:shares_basic]]
  end

  test "financials are symbol keyed rows in fiscal year order" do
    financials = Valuation.company_metrics("NVG")[:financials]
    assert_equal ValuationSeed::YEARS, financials.map { |f| f[:fiscal_year] }
    assert financials.all? { |f| f.key?(:nwc_change) && f.key?(:tax_rate) && f.key?(:is_estimate) }
  end

  test "a company without market data still reports its financials" do
    company = Company.create!(ticker: "PRIV", name: "Private Co", sector: ValuationSeed::SECTOR)
    company.financials.create!(fiscal_year: 2025, revenue: 100.0, ebitda: 20.0, eps: 1.0)
    metrics = Valuation.company_metrics("PRIV")
    assert_equal 0.0, metrics[:share_price]
    assert_nil metrics[:enterprise_value] # unknown, not zero
    assert_nil metrics[:week52_low]
    assert_nil metrics[:as_of]
    assert_nil metrics[:latest_actual][:ev_ebitda]
    assert_equal 0.0, metrics[:latest_actual][:pe]
  end

  test "a company without financials has no metrics" do
    Company.create!(ticker: "EMPT", name: "Empty Co")
    assert_nil Valuation.company_metrics("EMPT")
  end

  test "falls back to the latest estimate when there are no actuals" do
    company = Company.create!(ticker: "ESTO", name: "Estimates Only")
    company.financials.create!(fiscal_year: 2027, is_estimate: true, revenue: 100.0, ebitda: 20.0)
    metrics = Valuation.company_metrics("ESTO")
    assert_equal true, metrics[:latest_actual][:is_estimate]
    assert_equal 2027, metrics[:latest_actual][:fiscal_year]
  end
end

class ValuationCompsTest < ActiveSupport::TestCase
  setup { ValuationSeed.seed! }

  test "table excludes the target and sorts by size" do
    table = Valuation.comps_table(%w[NVG HLDX VLTR], exclude: "NVG")
    assert_not_includes table[:rows].map { |row| row[:ticker] }, "NVG"
    sizes = table[:rows].map { |row| row[:enterprise_value] }
    assert_equal sizes.sort.reverse, sizes
    assert_equal %w[VLTR HLDX], table[:rows].map { |row| row[:ticker] }
  end

  test "exclude is case insensitive and unknown tickers are skipped" do
    table = Valuation.comps_table(%w[nvg HLDX NOPE], exclude: "Nvg")
    assert_equal %w[HLDX], table[:rows].map { |row| row[:ticker] }
  end

  test "statistics bracket the observations" do
    table = Valuation.comps_table(%w[HLDX VLTR CRGD PYLN])
    stats = table[:stats][:ev_ebitda]
    observed = table[:rows].map { |row| row[:ev_ebitda] }
    assert_operator stats[:min], :<=, observed.min
    assert_operator stats[:max], :>=, observed.max
    assert_operator stats[:p25], :<=, stats[:median]
    assert_operator stats[:median], :<=, stats[:p75]
    assert_equal Valuation::MULTIPLE_LABELS, table[:labels]
  end

  test "statistics match the reference implementation" do
    stats = Valuation.comps_table(%w[HLDX VLTR CRGD PYLN TWSW MFCL])[:stats]
    assert_equal({ count: 6, min: 9.0, p25: 12.25, median: 15.25, p75: 17.88, max: 20.0, mean: 14.92 },
                 stats[:ev_ebitda])
    assert_equal({ count: 6, min: 1.56, p25: 2.61, median: 3.75, p75: 4.0, max: 4.09, mean: 3.24 },
                 stats[:ev_revenue])
  end

  test "rows carry the inputs behind each multiple" do
    row = Valuation.comps_table(%w[HLDX])[:rows].first
    assert_equal %i[ticker name country share_price price_date market_cap enterprise_value net_debt net_debt_as_of other_claims
                    shares_diluted shares_basic revenue ebitda ebitda_margin ev_revenue ev_ebitda pe fiscal_year basis period_type
                    ev_revenue_ntm ev_ebitda_ntm pe_ntm ntm_ebitda_derived],
                 row.keys
    assert_equal 141.0, row[:shares_diluted]
    assert_equal 1320.0, row[:revenue]
    assert_equal 2026, row[:fiscal_year]
    assert_equal "FY2026", row[:basis], "every multiple says which period it is on"
    assert_equal({ "FY2026" => 1 }, Valuation.comps_table(%w[HLDX])[:bases])
  end

  test "precedents include premium statistics" do
    precedents = Valuation.precedent_transactions
    assert_not_empty precedents[:rows]
    assert_includes precedents[:stats].keys, :premium_1day
    assert_operator precedents[:stats][:ev_ebitda][:count], :>, 0
    # Premiums are rounded to three places, multiples to two.
    assert_equal({ count: 6, min: 0.18, p25: 0.233, median: 0.28, p75: 0.305, max: 0.38, mean: 0.275 },
                 precedents[:stats][:premium_1day])
    assert_equal 16.93, precedents[:stats][:ev_ebitda][:p25]
  end

  test "precedents are newest first with symbol keys and dates" do
    rows = Valuation.precedent_transactions[:rows]
    assert_equal rows.map { |r| r[:announced_on] }.sort.reverse, rows.map { |r| r[:announced_on] }
    assert_kind_of Date, rows.first[:announced_on]
    assert_equal "Arclight Grid Software", rows.first[:target]
  end

  test "precedents filter by sector" do
    Transaction.create!(announced_on: "2026-01-01", target: "Other", acquirer: "Someone", sector: "Elsewhere",
                        ev_ebitda: 99.0)
    assert_equal 7, Valuation.precedent_transactions[:rows].size
    assert_equal 6, Valuation.precedent_transactions(sector: ValuationSeed::SECTOR)[:rows].size
    assert_equal 1, Valuation.precedent_transactions(sector: "Elsewhere")[:rows].size
    assert_equal 7, Valuation.precedent_transactions(sector: "")[:rows].size
  end

  test "precedents without any deals describe an empty distribution" do
    Transaction.delete_all
    precedents = Valuation.precedent_transactions
    assert_empty precedents[:rows]
    assert_equal 0, precedents[:stats][:ev_ebitda][:count]
    assert_nil precedents[:stats][:ev_ebitda][:p25]
  end
end

class ValuationImpliedValueTest < ActiveSupport::TestCase
  test "enterprise multiple bridges through net debt" do
    implied = Valuation.implied_from_multiple(10, 12, metric_value: 100, kind: "ev", net_debt: 200, shares: 50)
    assert_in_delta (10 * 100 - 200) / 50.0, implied[:low], 1e-9
    assert_in_delta (12 * 100 - 200) / 50.0, implied[:high], 1e-9
    assert_in_delta (implied[:low] + implied[:high]) / 2, implied[:mid], 1e-9
    assert_equal 100.0, implied[:metric_value]
    assert_equal [10.0, 12.0], [implied[:multiple_low], implied[:multiple_high]]
  end

  test "equity multiple applies directly" do
    implied = Valuation.implied_from_multiple(15, 20, metric_value: 2.0, kind: "equity", net_debt: 999, shares: 1)
    assert_in_delta 30.0, implied[:low], 1e-9
    assert_in_delta 40.0, implied[:high], 1e-9
  end

  test "inverted inputs are normalised" do
    implied = Valuation.implied_from_multiple(12, 10, metric_value: 100, kind: "ev", net_debt: 0, shares: 10)
    assert_operator implied[:low], :<, implied[:high]
    assert_equal 10.0, implied[:multiple_low]
  end

  test "outputs round half to even on exact ties, as the reference does" do
    # 0.125 and 0.375 are exact in binary, so Python's round() lands on the
    # even neighbour (0.12, 0.38); Ruby's Float#round would give 0.13 and 0.38.
    implied = Valuation.implied_from_multiple(1, 3, metric_value: 0.125, kind: "equity", net_debt: 0, shares: 1)
    assert_equal({ low: 0.12, high: 0.38, mid: 0.25, multiple_low: 1.0, multiple_high: 3.0, metric_value: 0.1 },
                 implied)
  end

  test "missing inputs return nil" do
    assert_nil Valuation.implied_from_multiple(nil, 12, metric_value: 100, kind: "ev", net_debt: 0, shares: 10)
    assert_nil Valuation.implied_from_multiple(10, nil, metric_value: 100, kind: "ev", net_debt: 0, shares: 10)
    assert_nil Valuation.implied_from_multiple(10, 12, metric_value: 0, kind: "ev", net_debt: 0, shares: 10)
    assert_nil Valuation.implied_from_multiple(10, 12, metric_value: 100, kind: "ev", net_debt: 0, shares: 0)
    assert_nil Valuation.implied_from_multiple(10, 12, metric_value: 100, kind: "ev", net_debt: 0, shares: nil)
  end
end

class ValuationDcfAssumptionsTest < ActiveSupport::TestCase
  test "defaults are the reference defaults" do
    a = Valuation::DcfAssumptions.new
    assert_equal 0.0, a.base_revenue
    assert_equal 0.12, a.revenue_growth
    assert_equal 0.25, a.ebitda_margin
    assert_equal 0.004, a.margin_expansion
    assert_equal 0.05, a.da_pct_revenue
    assert_equal 0.04, a.capex_pct_revenue
    assert_equal 0.012, a.nwc_pct_revenue
    assert_equal 0.23, a.tax_rate
    assert_equal 0.095, a.wacc
    assert_equal 0.025, a.terminal_growth
    assert_nil a.exit_multiple
    assert_equal 5, a.years
    assert_equal 0.0, a.net_debt
    assert_equal 0.0, a.other_claims
    assert_equal 1.0, a.shares_diluted
    assert_equal true, a.mid_year_convention
    assert_equal true, a.terminal_capex_floor
    assert_equal 1.0, a.stub_fraction
    assert_equal 2027, a.start_year
    assert_nil a.valuation_date
  end

  test "coerce parses the valuation date" do
    assert_equal Date.new(2026, 10, 12), Valuation::DcfAssumptions.coerce("valuation_date" => "2026-10-12")[:valuation_date]
    assert_equal Date.new(2026, 10, 12), Valuation::DcfAssumptions.coerce(valuation_date: Date.new(2026, 10, 12))[:valuation_date]
  end

  test "keyword initialiser and value equality" do
    a = Valuation::DcfAssumptions.new(base_revenue: 1000.0, wacc: 0.1)
    assert_equal 1000.0, a.base_revenue
    assert_equal 0.1, a.wacc
    assert_equal 0.025, a.terminal_growth
    assert_equal a, Valuation::DcfAssumptions.new(base_revenue: 1000.0, wacc: 0.1)
    assert_raises(ArgumentError) { Valuation::DcfAssumptions.new(nonsense: 1) }
  end

  test "coerce drops unknown and blank keys and casts by field" do
    clean = Valuation::DcfAssumptions.coerce(
      "wacc" => "0.08", :years => "6", "start_year" => 2028.0, "unknown" => 1, "exit_multiple" => "",
      "terminal_growth" => nil, "mid_year_convention" => "false"
    )
    assert_equal({ wacc: 0.08, years: 6, start_year: 2028, mid_year_convention: false }, clean)
    assert_equal({}, Valuation::DcfAssumptions.coerce(nil))
  end

  test "coerce reads form and JSON booleans" do
    cast = ->(v) { Valuation::DcfAssumptions.coerce(mid_year_convention: v)[:mid_year_convention] }
    assert_equal true, cast.call(true)
    assert_equal true, cast.call("1")
    assert_equal true, cast.call("true")
    assert_equal false, cast.call(false)
    assert_equal false, cast.call("0")
    assert_equal false, cast.call("false")
  end

  test "coerce rejects values that are not numbers" do
    assert_raises(ArgumentError) { Valuation::DcfAssumptions.coerce(wacc: "ten percent") }
    assert_raises(ArgumentError) { Valuation::DcfAssumptions.coerce(years: "6.5") }
  end

  test "from_h round trips a partial hash" do
    a = Valuation::DcfAssumptions.from_h("wacc" => "0.08", "years" => "6", "unknown" => 1, "exit_multiple" => "")
    assert_in_delta 0.08, a.wacc, 1e-9
    assert_equal 6, a.years
    assert_nil a.exit_multiple
    assert_equal 0.0, a.base_revenue
  end

  test "to_h has every field with symbol keys" do
    h = Valuation::DcfAssumptions.new(wacc: 0.1).to_h
    assert_equal Valuation::DcfAssumptions.members, h.keys
    assert_equal 20, h.size
    assert_equal 0.1, h[:wacc]
    assert_equal Valuation::DcfAssumptions.new(wacc: 0.1), Valuation::DcfAssumptions.new(**h)
  end

  test "with_overrides returns a new value and leaves the original alone" do
    base = Valuation::DcfAssumptions.new(base_revenue: 500.0, wacc: 0.1)
    tweaked = base.with_overrides("wacc" => 0.13, "years" => "7")
    assert_equal 0.13, tweaked.wacc
    assert_equal 7, tweaked.years
    assert_equal 500.0, tweaked.base_revenue
    assert_equal 0.1, base.wacc
    assert_equal 5, base.years
    assert_equal base, base.with_overrides({})
  end
end

class ValuationDcfTest < ActiveSupport::TestCase
  def base(**overrides)
    defaults = {
      base_revenue: 1000.0, revenue_growth: 0.10, ebitda_margin: 0.25, da_pct_revenue: 0.05,
      capex_pct_revenue: 0.04, nwc_pct_revenue: 0.01, tax_rate: 0.25, wacc: 0.10,
      terminal_growth: 0.02, years: 5, net_debt: 200.0, shares_diluted: 100.0
    }
    Valuation::DcfAssumptions.new(**defaults.merge(overrides))
  end

  test "projection shape and bridge" do
    result = Valuation.run_dcf(base)
    assert_equal 5, result[:projections].size
    assert_in_delta result[:pv_explicit] + result[:pv_terminal], result[:enterprise_value], 0.5
    assert_in_delta result[:enterprise_value] - 200.0, result[:equity_value], 0.5
    assert_in_delta result[:equity_value] / 100.0, result[:value_per_share], 0.05
    assert_equal %i[year revenue growth ebitda ebitda_margin ebit taxes dep_amort capex nwc_change fcf_full_year
                    period_fraction fcf discount_period discount_factor pv_fcf], result[:projections].first.keys
    # The bridge can be ticked and tied from the displayed rows.
    row = result[:projections].first
    assert_in_delta row[:ebit] - row[:taxes] + row[:dep_amort] - row[:capex] - row[:nwc_change], row[:fcf_full_year], 0.06
    assert_equal (2027..2031).to_a, result[:projections].map { |row| row[:year] }
  end

  test "result matches the hand-checked figures" do
    # Year 1 by hand: revenue 1,100; EBITDA at 25.4% = 279.4; D&A 55; EBIT 224.4; tax 56.1;
    # capex 44; working capital 1% of the 100 revenue increase = 1.0 (the reference
    # charged 1% of the revenue LEVEL, 11.0); FCF 178.3 discounted half a year at 10%.
    result = Valuation.run_dcf(base)
    assert_equal 820.4, result[:pv_explicit]
    assert_equal 2806.9, result[:terminal_value]
    assert_equal 1828.0, result[:pv_terminal]
    assert_equal "Gordon growth at 2.0%", result[:terminal_method]
    assert_equal 4.5, result[:terminal_discount_period]
    assert_equal 0.6902, result[:terminal_share_of_ev]
    assert_equal 2648.3, result[:enterprise_value]
    assert_equal 200.0, result[:net_debt]
    assert_equal 0.0, result[:other_claims]
    assert_equal 2448.3, result[:equity_value]
    assert_equal 24.48, result[:value_per_share]
    assert_equal 9.48, result[:implied_ev_ebitda]
    assert_equal 7.78, result[:implied_exit_multiple]
    assert_equal 0.02, result[:implied_terminal_growth], "a Gordon value implies its own growth back"
    assert_nil result[:bridge_note]
    assert_equal base.to_h, result[:assumptions]
    first = result[:projections].first
    assert_equal({ year: 2027, revenue: 1100.0, growth: 0.1, ebitda: 279.4, ebitda_margin: 0.254, ebit: 224.4,
                   taxes: 56.1, dep_amort: 55.0, capex: 44.0, nwc_change: 1.0, fcf_full_year: 178.3,
                   period_fraction: 1.0, fcf: 178.3, discount_period: 0.5, discount_factor: 0.9535, pv_fcf: 170.0 }, first)
    terminal = result[:terminal_year]
    assert_equal 2032, terminal[:year]
    assert_equal true, terminal[:capex_floored_at_da], "4% capex is below 5% D&A, so the terminal year carries D&A"
    assert_equal terminal[:dep_amort], terminal[:capex]
    assert_in_delta terminal[:ebit] - terminal[:taxes] + terminal[:dep_amort] - terminal[:capex] - terminal[:nwc_change], terminal[:fcf], 0.06
  end

  test "working capital follows the change in revenue, not its level" do
    flat = Valuation.run_dcf(base(revenue_growth: 0.0, terminal_growth: 0.0))
    assert_equal [0.0] * 5, flat[:projections].map { |row| row[:nwc_change] }
    assert_equal 0.0, flat[:terminal_year][:nwc_change]
    shrinking = Valuation.run_dcf(base(revenue_growth: -0.05, terminal_growth: 0.0))
    assert_operator shrinking[:projections].first[:nwc_change], :<, 0, "a revenue decline releases working capital"
  end

  test "an exit-multiple terminal value is discounted from year N even under the mid-year convention" do
    result = Valuation.run_dcf(base(exit_multiple: 12.0, mid_year_convention: true))
    assert_equal 5.0, result[:terminal_discount_period]
    assert_in_delta result[:terminal_value] / 1.1**5, result[:pv_terminal], 0.5
    gordon = Valuation.run_dcf(base(mid_year_convention: true))
    assert_equal 4.5, gordon[:terminal_discount_period], "a perpetuity of mid-year flows sits half a year earlier"
    assert_in_delta 0.0481, result[:implied_terminal_growth], 1e-4
  end

  test "a stub period counts only the remainder of the first year and shifts every discount" do
    result = Valuation.run_dcf(base(stub_fraction: 0.5))
    first, second = result[:projections]
    assert_equal 0.5, first[:period_fraction]
    assert_in_delta first[:fcf_full_year] / 2, first[:fcf], 0.06
    assert_equal 0.25, first[:discount_period]
    assert_equal 1.0, second[:discount_period]
    assert_equal 4.0, result[:terminal_discount_period]
    # Standing half a year later: half the first year's cash is gone, but every
    # remaining flow and the terminal value are discounted half a year less.
    whole = Valuation.run_dcf(base)
    assert_operator result[:pv_terminal], :>, whole[:pv_terminal]
    assert_in_delta whole[:pv_terminal] * 1.1**0.5, result[:pv_terminal], 0.5
    assert_raises(ArgumentError) { Valuation.run_dcf(base(stub_fraction: 0.0)) }
    assert_raises(ArgumentError) { Valuation.run_dcf(base(stub_fraction: 1.5)) }
  end

  test "unknown net debt gives an enterprise value and no equity bridge" do
    result = Valuation.run_dcf(base(net_debt: nil))
    assert_equal 2648.3, result[:enterprise_value]
    assert_nil result[:net_debt]
    assert_nil result[:equity_value]
    assert_nil result[:value_per_share]
    assert_includes result[:bridge_note], "Net debt unknown"
  end

  test "other claims are deducted with net debt" do
    result = Valuation.run_dcf(base(other_claims: 100.0))
    assert_equal 2348.3, result[:equity_value]
    assert_equal 23.48, result[:value_per_share]
  end

  test "the terminal capex floor can be switched off" do
    result = Valuation.run_dcf(base(terminal_capex_floor: false))
    assert_equal false, result[:terminal_year][:capex_floored_at_da]
    assert_operator result[:terminal_year][:capex], :<, result[:terminal_year][:dep_amort]
    assert_operator result[:value_per_share], :>, Valuation.run_dcf(base)[:value_per_share]
  end

  test "first year revenue applies growth" do
    result = Valuation.run_dcf(base)
    assert_in_delta 1100.0, result[:projections].first[:revenue], 0.05
  end

  test "growth fades towards terminal" do
    growths = Valuation.run_dcf(base)[:projections].map { |row| row[:growth] }
    assert_equal growths.sort.reverse, growths
    assert_operator growths.last, :>=, 0.02
  end

  test "growth interpolates linearly from the first year to the terminal rate, whatever its sign" do
    assert_equal [0.1, 0.08, 0.06, 0.04, 0.02], Valuation.run_dcf(base)[:projections].map { |row| row[:growth] }
    # The reference flipped a negative first year straight to the terminal rate in year 2.
    negative = Valuation.run_dcf(base(revenue_growth: -0.03, terminal_growth: 0.025))[:projections].map { |row| row[:growth] }
    assert_equal [-0.03, -0.0163, -0.0025, 0.0113, 0.025], negative
    assert_equal [0.1], Valuation.run_dcf(base(years: 1))[:projections].map { |row| row[:growth] }
  end

  test "higher wacc lowers value" do
    cheap = Valuation.run_dcf(base(wacc: 0.08))[:value_per_share]
    dear = Valuation.run_dcf(base(wacc: 0.12))[:value_per_share]
    assert_operator cheap, :>, dear
  end

  test "exit multiple overrides gordon growth" do
    result = Valuation.run_dcf(base(exit_multiple: 12.0))
    assert_includes result[:terminal_method], "exit EBITDA"
    assert_equal "12.0x exit EBITDA multiple", result[:terminal_method]
    assert_in_delta 12.0 * result[:projections].last[:ebitda], result[:terminal_value], 0.5
  end

  test "exit multiple makes terminal growth above wacc acceptable" do
    assert_nothing_raised { Valuation.run_dcf(base(exit_multiple: 10.0, terminal_growth: 0.11, wacc: 0.10)) }
  end

  test "mid year convention raises value" do
    mid = Valuation.run_dcf(base(mid_year_convention: true))[:value_per_share]
    year_end = Valuation.run_dcf(base(mid_year_convention: false))[:value_per_share]
    assert_operator mid, :>, year_end
    assert_equal 23.25, year_end
  end

  test "terminal growth above wacc is rejected" do
    assert_raises(ArgumentError) { Valuation.run_dcf(base(terminal_growth: 0.11, wacc: 0.10)) }
    assert_raises(ArgumentError) { Valuation.run_dcf(base(terminal_growth: 0.10, wacc: 0.10)) }
  end

  test "non positive wacc is rejected" do
    assert_raises(ArgumentError) { Valuation.run_dcf(base(wacc: 0.0)) }
    assert_raises(ArgumentError) { Valuation.run_dcf(base(wacc: -0.05)) }
  end

  test "zero base revenue is rejected" do
    assert_raises(ArgumentError) { Valuation.run_dcf(base(base_revenue: 0.0)) }
  end

  test "zero years is rejected" do
    assert_raises(ArgumentError) { Valuation.run_dcf(base(years: 0)) }
  end

  test "taxes floor at zero when ebit is negative" do
    result = Valuation.run_dcf(base(ebitda_margin: 0.01, margin_expansion: 0.0, da_pct_revenue: 0.05))
    assert result[:projections].all? { |row| row[:ebit].negative? && row[:taxes].zero? }
  end

  test "zero shares gives no per share value" do
    result = Valuation.run_dcf(base(shares_diluted: 0.0))
    assert_nil result[:value_per_share]
    assert_operator result[:equity_value], :>, 0
  end

  test "run_dcf also accepts a partial hash" do
    from_hash = Valuation.run_dcf(base.to_h.merge("wacc" => "0.1"))
    assert_equal Valuation.run_dcf(base)[:value_per_share], from_hash[:value_per_share]
  end

  test "partial overrides keep other assumptions" do
    original = base
    tweaked = original.with_overrides("wacc" => 0.13, "nonsense" => 1, "exit_multiple" => "")
    assert_in_delta 0.13, tweaked.wacc, 1e-9
    assert_in_delta original.base_revenue, tweaked.base_revenue, 1e-9
    assert_nil tweaked.exit_multiple
  end

  test "assumptions round trip from a hash" do
    assumptions = Valuation::DcfAssumptions.from_h("wacc" => "0.08", "years" => "6", "unknown" => 1,
                                                    "exit_multiple" => "")
    assert_in_delta 0.08, assumptions.wacc, 1e-9
    assert_equal 6, assumptions.years
    assert_nil assumptions.exit_multiple
  end

  test "sensitivity grid shape and monotonicity" do
    sensitivity = Valuation.dcf_sensitivity(base)
    assert_equal sensitivity[:terminal_axis].size, sensitivity[:grid].size
    assert_equal sensitivity[:wacc_axis].size, sensitivity[:grid].first.size
    # Along a row, a rising WACC must reduce value.
    row = sensitivity[:grid].first.compact
    assert_equal row.sort.reverse, row
    # Down a column, rising terminal growth must raise value.
    column = sensitivity[:grid].map(&:first).compact
    assert_equal column.sort, column
  end

  test "sensitivity defaults are plus or minus 150bps WACC and 100bps growth" do
    sensitivity = Valuation.dcf_sensitivity(base)
    assert_equal [0.085, 0.0925, 0.1, 0.1075, 0.115], sensitivity[:wacc_axis]
    assert_equal [0.01, 0.015, 0.02, 0.025, 0.03], sensitivity[:terminal_axis]
    assert_equal 18.54, sensitivity[:min]
    assert_equal 35.8, sensitivity[:max]
    assert_equal 24.48, sensitivity[:grid][2][2]
  end

  test "sensitivity blanks cells where growth reaches wacc" do
    sensitivity = Valuation.dcf_sensitivity(base, wacc_steps: [0.05, 0.10], terminal_steps: [0.05, 0.06])
    assert_equal [[true, false], [true, false]], sensitivity[:grid].map { |row| row.map(&:nil?) }
    assert_equal sensitivity[:grid].flatten.compact.min, sensitivity[:min]
    assert_equal sensitivity[:grid].flatten.compact.max, sensitivity[:max]
    assert_equal [0.05, 0.1], sensitivity[:wacc_axis]
  end

  test "sensitivity with no finite cell reports nil extremes" do
    sensitivity = Valuation.dcf_sensitivity(base, wacc_steps: [0.01], terminal_steps: [0.05])
    assert_equal [[nil]], sensitivity[:grid]
    assert_nil sensitivity[:min]
    assert_nil sensitivity[:max]
  end
end

class ValuationFootballFieldTest < ActiveSupport::TestCase
  COMPS = %w[HLDX VLTR CRGD PYLN TWSW MFCL].freeze

  setup do
    ValuationSeed.seed!
    @field = Valuation.football_field("NVG", COMPS)
  end

  test "every methodology is present" do
    methods = @field[:ranges].map { |row| row[:method] }
    %w[DCF 52-week\ trading\ range].each { |expected| assert_includes methods, expected }
    assert methods.any? { |method| method.include?("Trading comps") }
    assert methods.any? { |method| method.include?("Precedent") }
    assert_equal ["Trading comps — NTM EV/EBITDA", "Trading comps — EV/EBITDA", "Trading comps — EV/Revenue",
                  "Precedent transactions — EV/EBITDA", "DCF", "52-week trading range"], methods
  end

  test "the NTM comps bar leads, calendarised from the demo's estimate years, and names its derivation" do
    ntm = @field[:ranges].first
    assert_equal "Trading comps — NTM EV/EBITDA", ntm[:method]
    assert ntm[:in_conclusion]
    assert_match(/on NTM EBITDA of \d+ \(estimate rows; 6 peers\)/, ntm[:basis])
    metrics = Valuation.company_metrics("NVG")
    # Price date 9 October 2026: 83 days of FY2026 remain, so NTM is 22.7% FY2026 and 77.3% FY2027.
    assert_in_delta 83 / 365.25, metrics[:ntm][:weight_current_year], 1e-3
    assert_equal [2026, 2027], metrics[:ntm][:fiscal_years]
    assert_equal false, metrics[:ntm][:ebitda_derived], "the seeded estimate rows carry EBITDA"
    rows = metrics[:financials].select { |f| f[:period_type] == "FY" }
    fy26 = rows.find { |f| f[:fiscal_year] == 2026 }
    fy27 = rows.find { |f| f[:fiscal_year] == 2027 }
    w = metrics[:ntm][:weight_current_year]
    assert_in_delta w * fy26[:ebitda] + (1 - w) * fy27[:ebitda], metrics[:ntm][:ebitda], 0.06
    assert_in_delta metrics[:enterprise_value] / metrics[:ntm][:ebitda], metrics[:ntm][:ev_ebitda], 0.006
    stats = @field[:comps][:stats][:ev_ebitda_ntm]
    assert_equal 6, stats[:count]
    assert_operator stats[:median], :<, @field[:comps][:stats][:ev_ebitda][:median], "growing peers trade cheaper on forward EBITDA"
  end

  test "no NTM bar without three peers carrying an NTM multiple" do
    field = Valuation.football_field("NVG", %w[HLDX VLTR])
    refute_includes field[:ranges].map { |r| r[:method] }, "Trading comps — NTM EV/EBITDA"
    assert_equal 2, field[:comps][:stats][:ev_ebitda_ntm][:count]
  end

  test "ranges are ordered and documented" do
    @field[:ranges].each do |row|
      assert_operator row[:low], :<=, row[:high]
      assert_in_delta (row[:low] + row[:high]) / 2, row[:mid], 0.006
      assert_kind_of String, row[:basis]
      assert_kind_of Hash, row[:detail]
    end
  end

  test "ranges match the reference implementation" do
    by_method = @field[:ranges].to_h { |row| [row[:method], row] }
    comps = by_method["Trading comps — EV/EBITDA"]
    assert_equal [30.2, 45.11], [comps[:low], comps[:high]]
    assert_equal "12.25x–17.88x on FY2026 EBITDA of 482", comps[:basis]
    assert_equal 482.1, comps[:detail][:metric_value]
    # The bar's mid is recomputed from the rounded ends (37.655 -> 37.66) while
    # the detail keeps the unrounded mid (37.65), exactly as the reference does.
    assert_equal 37.66, comps[:mid]
    assert_equal 37.65, comps[:detail][:mid]
    revenue = by_method["Trading comps — EV/Revenue"]
    assert_equal [24.13, 38.19], [revenue[:low], revenue[:high]]
    assert_equal "2.61x–4.0x on FY2026 revenue of 1840", revenue[:basis]
    precedent = by_method["Precedent transactions — EV/EBITDA"]
    assert_equal [42.59, 56.34], [precedent[:low], precedent[:high]]
    assert_equal "16.93x–22.12x on FY2026 EBITDA (6 deals)", precedent[:basis]
    dcf = by_method["DCF"]
    assert_equal [27.27, 41.2], [dcf[:low], dcf[:high]]
    assert_equal "WACC 10.02% ±100bps, terminal growth 2.50% ±50bps", dcf[:basis]
    assert_equal({ base_case: @field[:dcf][:value_per_share] }, dcf[:detail])
    assert_equal 32.85, @field[:dcf][:value_per_share]
  end

  test "reference bars and a revenue multiple on a margin outlier stay out of the conclusion" do
    by_method = @field[:ranges].to_h { |row| [row[:method], row] }
    week = by_method["52-week trading range"]
    assert_equal false, week[:in_conclusion]
    assert_equal true, week[:reference]
    revenue = by_method["Trading comps — EV/Revenue"]
    assert_equal false, revenue[:in_conclusion]
    assert_match(/outside the peer interquartile range/, revenue[:note])
    assert @field[:ranges].reject { |r| r == week || r == revenue }.all? { |r| r[:in_conclusion] }
    assert_equal ["Trading comps — NTM EV/EBITDA", "Trading comps — EV/EBITDA", "Precedent transactions — EV/EBITDA", "DCF"],
                 @field[:concluded_range][:methods]
  end

  test "the WACC is built from its parts and shown with the field" do
    build = @field[:wacc]
    assert_equal 1.21, build[:beta]
    assert_equal false, build[:beta_assumed]
    assert_in_delta 0.0425 + 1.21 * 0.05, build[:cost_of_equity], 1e-4
    assert_in_delta 0.06 * (1 - 0.23), build[:after_tax_cost_of_debt], 1e-4
    assert_in_delta 410.0 / (8026.2 + 410.0), build[:weight_debt], 1e-4
    assert_equal 0.1002, build[:wacc]
    assert_equal build[:wacc], @field[:dcf][:assumptions][:wacc]
    assert build[:notes].any? { |n| n.include?("house defaults") }
  end

  test "target block and reference price come from the market data" do
    assert_equal({ ticker: "NVG", name: "NovaGrid Systems", share_price: 44.1, shares_diluted: 182.0,
                   net_debt: 410.0, other_claims: 0.0, currency: "USD", market_cap: 8026.2, enterprise_value: 8436.2,
                   basis_label: "FY2026", price_date: Date.new(2026, 10, 9), balance_sheet_date: nil },
                 @field[:target])
    assert_equal 44.1, @field[:reference_price]
    assert_equal 6, @field[:comps][:rows].size
    assert_equal 6, @field[:precedents][:rows].size
    assert_equal 32.85, @field[:dcf][:value_per_share]
    assert_equal [24.51, 49.45], [@field[:sensitivity][:min], @field[:sensitivity][:max]]
  end

  test "axis pads the extremes by ten and five percent" do
    lows = @field[:ranges].map { |row| row[:low] }
    highs = @field[:ranges].map { |row| row[:high] }
    assert_in_delta lows.min * 0.9, @field[:axis][:min], 0.006
    assert_in_delta highs.max * 1.05, @field[:axis][:max], 0.006
  end

  test "concluded range sits inside the methodologies" do
    concluded = @field[:concluded_range]
    lows = @field[:ranges].select { |r| r[:in_conclusion] }.map { |row| row[:low] }
    highs = @field[:ranges].select { |r| r[:in_conclusion] }.map { |row| row[:high] }
    assert_operator concluded[:low], :>=, lows.min
    assert_operator concluded[:high], :<=, highs.max
    assert_operator concluded[:low], :<, concluded[:high]
  end

  test "concluded range is the median low to the median high of the valuation methods" do
    counted = @field[:ranges].select { |r| r[:in_conclusion] }
    assert_in_delta Valuation.percentile(counted.map { |r| r[:low] }, 0.5), @field[:concluded_range][:low], 0.006
    assert_in_delta Valuation.percentile(counted.map { |r| r[:high] }, 0.5), @field[:concluded_range][:high], 0.006
    assert_equal({ low: 31.03, high: 44.8, methods: counted.map { |r| r[:method] } }, @field[:concluded_range])
  end

  test "dcf bar uses the narrow band while the sensitivity shows the wide grid" do
    dcf = @field[:ranges].find { |row| row[:method] == "DCF" }
    assumptions = Valuation::DcfAssumptions.new(**@field[:dcf][:assumptions])
    band = Valuation.dcf_sensitivity(
      assumptions,
      wacc_steps: [-0.01, 0.0, 0.01].map { |d| assumptions.wacc + d },
      terminal_steps: [-0.005, 0.0, 0.005].map { |d| assumptions.terminal_growth + d }
    )
    assert_equal [band[:min], band[:max]], [dcf[:low], dcf[:high]]
    assert_operator @field[:sensitivity][:min], :<, dcf[:low]
    assert_operator @field[:sensitivity][:max], :>, dcf[:high]
    assert_equal 5, @field[:sensitivity][:wacc_axis].size
    assert_in_delta assumptions.wacc - 0.015, @field[:sensitivity][:wacc_axis].first, 1e-4
    assert_in_delta assumptions.terminal_growth - 0.01, @field[:sensitivity][:terminal_axis].first, 1e-4
  end

  test "assumption overrides change the dcf" do
    tighter = Valuation.football_field("NVG", %w[HLDX VLTR], assumptions: { "wacc" => 0.14 })
    base_dcf = @field[:ranges].find { |row| row[:method] == "DCF" }
    tight_dcf = tighter[:ranges].find { |row| row[:method] == "DCF" }
    assert_operator tight_dcf[:mid], :<, base_dcf[:mid]
    assert_equal "WACC 14.00% ±100bps, terminal growth 2.50% ±50bps", tight_dcf[:basis]
    assert_equal 0.14, tighter[:dcf][:assumptions][:wacc]
    assert_equal [18.43, 24.19], [tight_dcf[:low], tight_dcf[:high]]
  end

  test "unknown target" do
    assert_raises(ArgumentError) { Valuation.football_field("NOPE", %w[HLDX]) }
  end

  test "default assumptions follow company history" do
    metrics = Valuation.company_metrics("NVG")
    assumptions = Valuation.default_assumptions(metrics)
    assert_in_delta metrics[:latest_actual][:revenue], assumptions.base_revenue, 0.05
    assert_in_delta metrics[:net_debt], assumptions.net_debt, 0.05
    assert_operator assumptions.wacc, :>, 0
    assert_equal 0.1002, assumptions.wacc
    assert_equal 1.0, assumptions.stub_fraction, "FY2027 has not started at the 9 October 2026 price date"
    assert_equal Date.new(2026, 10, 9), assumptions.valuation_date
    assert_equal 0.0, assumptions.other_claims
    assert_equal 0.168, assumptions.revenue_growth
    assert_equal 0.262, assumptions.ebitda_margin
    assert_equal 0.052, assumptions.da_pct_revenue
    assert_equal 0.041, assumptions.capex_pct_revenue
    assert_equal 0.012, assumptions.nwc_pct_revenue
    assert_equal 0.23, assumptions.tax_rate
    assert_equal 182.0, assumptions.shares_diluted
    assert_equal 2027, assumptions.start_year
    assert_kind_of Valuation::DcfAssumptions, assumptions
  end
end

class ValuationFootballFieldWithoutPrecedentsTest < ActiveSupport::TestCase
  setup do
    ValuationSeed.seed!(transactions: false)
    @field = Valuation.football_field("NVG", %w[HLDX VLTR CRGD])
  end

  test "the precedent bar is omitted rather than fabricated" do
    methods = @field[:ranges].map { |row| row[:method] }
    assert_equal ["Trading comps — NTM EV/EBITDA", "Trading comps — EV/EBITDA", "Trading comps — EV/Revenue", "DCF",
                  "52-week trading range"], methods
    assert_empty @field[:precedents][:rows]
    assert_equal 0, @field[:precedents][:stats][:ev_ebitda][:count]
  end

  test "concluded range still comes from the remaining bars" do
    counted = @field[:ranges].select { |r| r[:in_conclusion] }
    assert_in_delta Valuation.percentile(counted.map { |r| r[:low] }, 0.5), @field[:concluded_range][:low], 0.006
    assert_in_delta Valuation.percentile(counted.map { |r| r[:high] }, 0.5), @field[:concluded_range][:high], 0.006
  end

  test "a target without a 52-week range drops that bar too" do
    Company.find_ticker("NVG").market_datum.update!(week52_low: nil, week52_high: 0.0)
    field = Valuation.football_field("NVG", %w[HLDX VLTR CRGD])
    assert_not_includes field[:ranges].map { |row| row[:method] }, "52-week trading range"
  end

  test "a target with no comps still gets a dcf" do
    field = Valuation.football_field("NVG", [])
    assert_equal ["DCF", "52-week trading range"], field[:ranges].map { |row| row[:method] }
    assert_equal 0, field[:comps][:stats][:ev_ebitda][:count]
  end
end

class ValuationDefaultAssumptionsTest < ActiveSupport::TestCase
  def metrics_with(financials, beta: 1.0, net_debt: 100.0, shares: 10.0)
    { financials: financials, beta: beta, net_debt: net_debt, shares_diluted: shares }
  end

  def year(fiscal_year, revenue:, nwc_change: nil, tax_rate: nil, is_estimate: false, **rest)
    { fiscal_year: fiscal_year, is_estimate: is_estimate, revenue: revenue, ebitda: revenue * 0.2,
      dep_amort: revenue * 0.05, capex: revenue * 0.04, nwc_change: nwc_change, tax_rate: tax_rate }.merge(rest)
  end

  test "working capital intensity is a three year average" do
    history = [
      year(2022, revenue: 100.0, nwc_change: 50.0),   # outside the window, ignored
      year(2023, revenue: 100.0, nwc_change: 1.0),
      year(2024, revenue: 100.0, nwc_change: 2.0),
      year(2025, revenue: 100.0, nwc_change: 3.0),
      year(2026, revenue: 100.0, nwc_change: 99.0, is_estimate: true) # estimates never count
    ]
    assert_in_delta 0.02, Valuation.default_assumptions(metrics_with(history)).nwc_pct_revenue, 1e-9
  end

  test "working capital intensity is clamped to minus three and plus five percent" do
    heavy = [year(2024, revenue: 100.0, nwc_change: 8.0), year(2025, revenue: 100.0, nwc_change: 12.0)]
    assert_in_delta 0.05, Valuation.default_assumptions(metrics_with(heavy)).nwc_pct_revenue, 1e-9
    release = [year(2024, revenue: 100.0, nwc_change: -10.0), year(2025, revenue: 100.0, nwc_change: -20.0)]
    assert_in_delta(-0.03, Valuation.default_assumptions(metrics_with(release)).nwc_pct_revenue, 1e-9)
  end

  test "working capital falls back when no year reports it" do
    assert_in_delta 0.012, Valuation.default_assumptions(metrics_with([year(2025, revenue: 100.0)])).nwc_pct_revenue, 1e-9
  end

  test "tax rate is clamped to a normalised band" do
    assert_in_delta 0.35, Valuation.default_assumptions(metrics_with([year(2025, revenue: 100.0, tax_rate: 0.6)])).tax_rate, 1e-9
    assert_in_delta 0.15, Valuation.default_assumptions(metrics_with([year(2025, revenue: 100.0, tax_rate: 0.02)])).tax_rate, 1e-9
    assert_in_delta 0.21, Valuation.default_assumptions(metrics_with([year(2025, revenue: 100.0, tax_rate: 0.21)])).tax_rate, 1e-9
    assert_in_delta 0.23, Valuation.default_assumptions(metrics_with([year(2025, revenue: 100.0)])).tax_rate, 1e-9
  end

  test "growth comes from the last two actuals and is clamped" do
    assert_in_delta 0.2, Valuation.default_assumptions(metrics_with([year(2024, revenue: 100.0), year(2025, revenue: 120.0)])).revenue_growth, 1e-9
    assert_in_delta 0.45, Valuation.default_assumptions(metrics_with([year(2024, revenue: 100.0), year(2025, revenue: 300.0)])).revenue_growth, 1e-9
    assert_in_delta(-0.1, Valuation.default_assumptions(metrics_with([year(2024, revenue: 100.0), year(2025, revenue: 50.0)])).revenue_growth, 1e-9)
    assert_in_delta 0.10, Valuation.default_assumptions(metrics_with([year(2025, revenue: 100.0)])).revenue_growth, 1e-9
    assert_in_delta 0.10, Valuation.default_assumptions(metrics_with([year(2024, revenue: 0.0), year(2025, revenue: 100.0)])).revenue_growth, 1e-9
  end

  test "the WACC is a CAPM build: beta moves the cost of equity, debt is weighted at its after-tax cost" do
    # No market cap in these metrics: all-equity, so WACC = rf + beta x ERP.
    assert_in_delta 0.0925, Valuation.default_assumptions(metrics_with([year(2025, revenue: 100.0)], beta: 1.0)).wacc, 1e-9
    assert_in_delta 0.1175, Valuation.default_assumptions(metrics_with([year(2025, revenue: 100.0)], beta: 1.5)).wacc, 1e-9
    unknown = Valuation.wacc_build(metrics_with([year(2025, revenue: 100.0)], beta: nil))
    assert_in_delta 0.0925, unknown[:wacc], 1e-9
    assert unknown[:beta_assumed]
    assert unknown[:notes].any? { |n| n.include?("Beta not loaded") }
    levered = Valuation.wacc_build(metrics_with([year(2025, revenue: 100.0)], beta: 1.0).merge(market_cap: 900.0, net_debt: 100.0))
    assert_in_delta 0.1, levered[:weight_debt], 1e-9
    assert_in_delta 0.9 * 0.0925 + 0.1 * 0.06 * 0.77, levered[:wacc], 1e-4
    assert_equal 0.23, levered[:tax_rate]
  end

  test "capital structure and start year" do
    a = Valuation.default_assumptions(metrics_with([year(2025, revenue: 100.0)], net_debt: 42.0, shares: 7.0))
    assert_equal 42.0, a.net_debt
    assert_equal 7.0, a.shares_diluted
    assert_equal 2026, a.start_year
    assert_equal 0.025, a.terminal_growth
    assert_equal 0.2, a.ebitda_margin
    assert_equal 0.05, a.da_pct_revenue
    assert_equal 0.04, a.capex_pct_revenue
    assert_nil Valuation.default_assumptions(metrics_with([year(2025, revenue: 100.0)], shares: 0.0)).shares_diluted,
               "an unknown share count stays unknown instead of becoming one share"
    assert_nil Valuation.default_assumptions(metrics_with([year(2025, revenue: 100.0)], net_debt: nil)).net_debt
  end

  test "the stub period runs from the price date to the end of the first projected year" do
    metrics = metrics_with([year(2025, revenue: 100.0, period_end: Date.new(2025, 12, 31))]).merge(as_of: Date.new(2026, 10, 12))
    a = Valuation.default_assumptions(metrics)
    assert_equal 2026, a.start_year
    assert_in_delta 80 / 365.25, a.stub_fraction, 1e-3, "80 days of FY2026 remain on 12 October 2026"
    assert_equal Date.new(2026, 10, 12), a.valuation_date
    whole = Valuation.default_assumptions(metrics.merge(as_of: Date.new(2026, 1, 1)))
    assert_in_delta 364 / 365.25, whole.stub_fraction, 1e-3
    assert_equal 1.0, Valuation.default_assumptions(metrics.merge(as_of: Date.new(2025, 6, 1))).stub_fraction, "capped at a whole year"
  end

  test "margin, D&A and capex intensity come from the LTM row when there is one" do
    ltm = year(2025, revenue: 110.0, period_type: "LTM", period_end: Date.new(2026, 6, 30)).merge(ebitda: 33.0)
    a = Valuation.default_assumptions(metrics_with([year(2024, revenue: 90.0), year(2025, revenue: 100.0), ltm]))
    assert_equal 100.0, a.base_revenue, "the projection still starts from the last fiscal year"
    assert_equal 0.3, a.ebitda_margin
    assert_in_delta 100.0 / 90.0 - 1, a.revenue_growth, 1e-3
  end

  test "no history at all yields the generic defaults" do
    a = Valuation.default_assumptions(metrics_with([]))
    assert_equal 0.0, a.base_revenue
    assert_equal 0.2, a.ebitda_margin
    assert_equal 2027, a.start_year
    assert_raises(ArgumentError) { Valuation.run_dcf(a) }
  end
end


class ValuationNtmTest < ActiveSupport::TestCase
  setup do
    @company = Company.create!(ticker: "NTMX", name: "Forward Co", sector: "Test")
    Financial.create!(company: @company, fiscal_year: 2025, period_end: Date.new(2025, 12, 31), revenue: 2400.0, ebitda: 360.0, ebit: 300.0, eps: 5.0)
    Financial.create!(company: @company, fiscal_year: 2026, period_end: Date.new(2026, 12, 31), is_estimate: true, revenue: 2388.1, eps: 6.42,
                      estimate_source: "consensus (Yahoo Finance, 9 analysts)")
    Financial.create!(company: @company, fiscal_year: 2027, period_end: Date.new(2027, 12, 31), is_estimate: true, revenue: 2553.2, eps: 7.0,
                      estimate_source: "consensus (Yahoo Finance, 9 analysts)")
    MarketDatum.create!(company: @company, as_of: Date.new(2026, 10, 12), share_price: 85.57, shares_diluted: 46.32, net_debt: 830.0)
  end

  teardown { @company.destroy }

  test "NTM blends the fiscal year in progress and the next by the time remaining, deriving EBITDA at the current margin" do
    ntm = Valuation.company_metrics("NTMX")[:ntm]
    w = 80 / 365.25 # 12 October to 31 December 2026
    assert_in_delta w, ntm[:weight_current_year], 1e-3
    assert_in_delta w * 2388.1 + (1 - w) * 2553.2, ntm[:revenue], 0.06
    assert_in_delta w * 6.42 + (1 - w) * 7.0, ntm[:eps], 0.006
    assert ntm[:ebitda_derived]
    assert_in_delta ntm[:revenue] * 0.15, ntm[:ebitda], 0.06, "FY2025 margin of 15% applied to NTM revenue"
    ev = 85.57 * 46.32 + 830.0
    assert_in_delta ev / ntm[:ebitda], ntm[:ev_ebitda], 0.006
    assert_in_delta 85.57 / ntm[:eps], ntm[:pe], 0.006
    assert_equal [2026, 2027], ntm[:fiscal_years]
    assert_equal "consensus (Yahoo Finance, 9 analysts)", ntm[:source]
  end

  test "NTM is nil without an estimate beyond the current year" do
    Financial.where(company: @company, is_estimate: true).delete_all
    assert_nil Valuation.company_metrics("NTMX")[:ntm]
    row = Valuation.comps_table(%w[NTMX])[:rows].first
    assert_nil row[:ev_ebitda_ntm]
    assert_equal 0, Valuation.comps_table(%w[NTMX])[:stats][:ev_ebitda_ntm][:count]
  end

  test "a price date past the current fiscal year end rolls NTM to the next year" do
    @company.market_datum.update!(as_of: Date.new(2027, 1, 15))
    ntm = Valuation.company_metrics("NTMX")[:ntm]
    assert_equal [2027], ntm[:fiscal_years], "FY2026 is over; only FY2027 lies ahead"
    assert_in_delta 2553.2, ntm[:revenue], 0.06
  end
end

class ValuationUnknownNetDebtTest < ActiveSupport::TestCase
  setup do
    @company = Company.create!(ticker: "NODEBT", name: "No Balance Sheet Co", sector: "Test")
    Financial.create!(company: @company, fiscal_year: 2025, is_estimate: false, revenue: 1000.0, ebitda: 200.0, ebit: 150.0, eps: 2.0)
    MarketDatum.create!(company: @company, share_price: 40.0, shares_diluted: 50.0, net_debt: nil)
  end

  teardown { @company.destroy }

  test "unknown net debt leaves EV and EV multiples unknown rather than zero" do
    metrics = Valuation.company_metrics("NODEBT")
    assert_nil metrics[:net_debt]
    assert_nil metrics[:enterprise_value]
    assert_nil metrics[:latest_actual][:ev_ebitda]
    assert_nil metrics[:latest_actual][:ev_revenue]
    assert_in_delta 20.0, metrics[:latest_actual][:pe], 0.01, "equity multiples still work"
    assert_in_delta 2000.0, metrics[:market_cap], 0.01
  end

  test "a peer without net debt is excluded from EV statistics" do
    stats = Valuation.comps_table(["NODEBT"])[:stats]
    assert_equal 0, stats[:ev_ebitda][:count]
    assert_equal 1, stats[:pe][:count]
  end

  test "an EV multiple cannot be bridged to a share price without net debt" do
    assert_nil Valuation.implied_from_multiple(10, 12, metric_value: 100, kind: "ev", net_debt: nil, shares: 10)
    refute_nil Valuation.implied_from_multiple(10, 12, metric_value: 2.0, kind: "equity", net_debt: nil, shares: 10)
    assert_equal 8.0, Valuation.implied_from_multiple(10, 10, metric_value: 100, kind: "ev", net_debt: 100, shares: 100, other_claims: 100)[:low]
  end

  test "the football field for a target with unknown net debt has no DCF bar and no concluded range" do
    field = Valuation.football_field("NODEBT", [])
    assert_empty field[:ranges].map { |r| r[:method] } - ["52-week trading range"]
    assert_includes field[:dcf_note], "Net debt unknown"
    assert_nil field[:dcf][:value_per_share]
    assert_equal({ low: nil, high: nil, methods: [] }, field[:concluded_range])
  end
end
