# frozen_string_literal: true

require "test_helper"

# The evaluation engine on synthetic data whose answer is known by construction.
class BacktestRunnerTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  ANCHOR = 2016
  N = 40

  setup do
    teardown_data
    ciks = (1..N).map { |i| 9000 + i }
    members = ciks.each_with_index.map do |cik, i|
      { cik: cik, ticker: "T#{i + 1}", name: "Synthetic #{i + 1}", sic: i.even? ? "3500" : "3800",
        anchor_year: ANCHOR, has_prices: true, revenue_anchor: 1e9 }
    end
    UniverseMember.insert_all(members)

    # Every company earns the same EBITDA (100) and starts at a multiple from
    # 5x to 25x. Each month a name's return is driven by how cheap it is
    # against the cross-section median *that month*, so multiples mean-revert
    # and the signal -> return relationship holds on every date rather than
    # reversing once the cheap names have re-rated.
    facts = []
    ciks.each_with_index do |cik, i|
      (2016..2025).each do |fy|
        filed = Date.new(fy + 1, 2, 20)
        base = { cik: cik, ticker: "T#{i + 1}", fiscal_year: fy, filed: filed, form: "10-K" }
        facts << base.merge(concept: "operating_income", period_start: Date.new(fy, 1, 1), period_end: Date.new(fy, 12, 31), value: 80.0)
        facts << base.merge(concept: "dep_amort", period_start: Date.new(fy, 1, 1), period_end: Date.new(fy, 12, 31), value: 20.0)
        facts << base.merge(concept: "cash", period_start: nil, period_end: Date.new(fy, 12, 31), value: 50.0)
        facts << base.merge(concept: "debt_noncurrent", period_start: nil, period_end: Date.new(fy, 12, 31), value: 50.0)
        facts << base.merge(concept: "shares_cover", period_start: nil, period_end: Date.new(fy + 1, 2, 10), value: 100.0)
      end
    end
    # The engine values a name on `close` and measures returns on `adj_close`,
    # so the fixture can hold every multiple fixed (cheap names stay cheap) and
    # let the adjusted series compound at a rate set by cheapness against the
    # cross-section median. The signal is then constant per name and forward
    # returns are monotone in it on every date, which is what the engine must
    # recover.
    bars = []
    multiples = (0...N).map { |i| 5.0 + 20.0 * i / (N - 1.0) }
    median = multiples.sort[N / 2]
    growth = multiples.map { |m| 0.005 + 0.03 * Math.log(median / m) }
    # Seeded noise: a perfect signal has an IC of exactly 1 on every date, and a
    # constant series has no variance for a t-statistic to be computed from.
    noise = Random.new(42)
    levels = Array.new(N, 1.0)
    month = Date.new(2017, 1, 31)
    while month <= Date.new(2026, 9, 30)
      multiples.each_with_index do |m, i|
        bars << { ticker: "T#{i + 1}", month_end: month, close: m, adj_close: levels[i].round(8),
                  source: "synthetic", adjusted: true }
        levels[i] *= (1 + growth[i] + noise.rand(-0.02..0.02))
      end
      month = Date.new((month >> 1).year, (month >> 1).month, -1)
    end
    PitFact.insert_all(facts, unique_by: %i[cik concept period_end filed])
    PriceBar.insert_all(bars, unique_by: %i[ticker month_end])
  end

  teardown { teardown_data }

  def teardown_data
    UniverseMember.where(anchor_year: ANCHOR, cik: 9001..9040).delete_all
    PitFact.where(cik: 9001..9040).delete_all
    PriceBar.where("ticker LIKE 'T%'").delete_all
    BacktestRun.where(name: "synthetic").delete_all
  end

  test "cheap-versus-peers ranks forward returns when the data says it should" do
    results = Backtest::Runner.run!(name: "synthetic", anchor_year: ANCHOR, persist: false)
    twelve = results[:horizons][12]
    assert_operator twelve[:n_dates], :>, 80
    assert_operator twelve[:mean_ic], :>, 0.8, "cheap names were built to outperform"
    assert_equal 1.0, twelve[:hit_rate]
    assert_operator twelve[:spread_annualised], :>, 0.2
    assert_operator twelve[:t_newey_west], :>, 2.0
    assert_equal N, twelve[:avg_names]
  end

  test "nothing is known before it is filed" do
    data = Backtest::Runner.load(ANCHOR)
    assert_empty Backtest::Runner.cross_section(data, Date.new(2017, 1, 31)), "FY2016 10-Ks are filed on 20 Feb 2017"
    rows = Backtest::Runner.cross_section(data, Date.new(2017, 2, 28))
    assert_equal N, rows.size
  end

  test "stale fundamentals drop out after eighteen months" do
    PitFact.where(cik: 9001, fiscal_year: 2018..2025).delete_all
    data = Backtest::Runner.load(ANCHOR)
    assert Backtest::Runner.cross_section(data, Date.new(2018, 12, 31)).any? { |r| r.cik == 9001 }, "FY2017 still fresh"
    refute Backtest::Runner.cross_section(data, Date.new(2019, 8, 31)).any? { |r| r.cik == 9001 }, "FY2017 is now stale"
  end

  test "unknown net debt excludes a name rather than assuming zero" do
    PitFact.where(cik: 9002, concept: %w[cash debt_noncurrent]).delete_all
    data = Backtest::Runner.load(ANCHOR)
    refute Backtest::Runner.cross_section(data, Date.new(2018, 6, 30)).any? { |r| r.cik == 9002 }
  end

  test "peer groups fall back to the whole cross-section when a sector is thin" do
    UniverseMember.where(cik: 9001).update_all(sic: "9900")
    data = Backtest::Runner.load(ANCHOR)
    rows = Backtest::Runner.cross_section(data, Date.new(2018, 6, 30))
    lonely = rows.find { |r| r.cik == 9001 }
    assert_equal "ALL", lonely.peer_group
    assert_equal "35", rows.find { |r| r.cik == 9003 }.peer_group
  end

  test "a run persists and a report is written with its charts" do
    run = Backtest::Runner.run!(name: "synthetic", anchor_year: ANCHOR)
    assert_kind_of BacktestRun, run
    Dir.mktmpdir do |dir|
      path = Backtest::Report.write(run, dir: dir)
      md = File.read(path)
      assert_includes md, "Known biases"
      assert_includes md, "| 12m |"
      assert File.exist?(File.join(dir, "synthetic-ic-by-horizon.svg"))
      assert File.exist?(File.join(dir, "synthetic-ic-12m.svg"))
      assert_includes File.read(File.join(dir, "synthetic-ic-12m.svg")), "<svg"
    end
  end
end

class BacktestStatsTest < ActiveSupport::TestCase
  test "spearman handles ties and perfect orders" do
    assert_in_delta 1.0, Backtest::Stats.spearman([1, 2, 3, 4], [10, 20, 30, 40]), 1e-9
    assert_in_delta(-1.0, Backtest::Stats.spearman([1, 2, 3, 4], [40, 30, 20, 10]), 1e-9)
    assert_equal [1.5, 1.5, 3.0], Backtest::Stats.ranks([5, 5, 9])
    assert_nil Backtest::Stats.spearman([1, 1, 1], [1, 2, 3]), "no variance"
  end

  test "newey-west with zero lags is the plain t-statistic" do
    series = [0.1, 0.3, 0.2, 0.4, 0.0, 0.2]
    plain = Backtest::Stats.mean(series) / (Backtest::Stats.stddev(series) / Math.sqrt(series.size))
    # Newey–West divides the autocovariance by n where the sample variance
    # divides by n - 1, so the two differ by exactly sqrt(n / (n - 1)).
    nw = Backtest::Stats.newey_west_t(series, lags: 0)
    assert_in_delta plain * Math.sqrt(series.size / (series.size - 1.0)), nw, 1e-9
  end

  test "quintiles bucket by descending sort key" do
    key = (1..10).to_a
    payoff = key.map { |k| k * 10.0 }
    means = Backtest::Stats.quintile_means(key, payoff)
    assert_equal 5, means.size
    assert_in_delta 95.0, means.first, 1e-9, "bucket 1 holds the highest keys"
    assert_in_delta 15.0, means.last, 1e-9
  end
end

# A cross-section small enough to compute by hand. Every expected value below
# was worked out on paper from the fixture, so the assertions are exact and
# a timing error (a backward window, an off-by-one month, a price or filing
# read from the future) changes them.
class BacktestHandComputedTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  ANCHOR = 2016
  T = Date.new(2017, 2, 28)
  NAMES = { 9101 => "HA", 9102 => "HB", 9103 => "HC", 9104 => "HD", 9105 => "HE" }.freeze
  # Yahoo-style stored closes at T. HE has a 2:1 split on 2017-04-15, so its
  # stored closes before that date are half the raw price.
  CLOSES_AT_T = { "HA" => 50.0, "HB" => 100.0, "HC" => 150.0, "HD" => 200.0, "HE" => 12.5 }.freeze
  # adj_close by month for the five names, in the order HA HB HC HD HE. 1.0
  # wherever a month is not listed. Chosen so that only the correct forward
  # window ranks like the signal (HE > HA > HB > HC > HD):
  #   t-3 (backward window) and t+2 / t+4 (off-by-one) rank the other way.
  ADJ = {
    Date.new(2016, 11, 30) => [1.3, 1.2, 1.1, 1.0, 1.4],
    Date.new(2017, 4, 30) => [1.0, 1.1, 1.2, 1.3, 0.9],
    Date.new(2017, 5, 31) => [1.4, 1.3, 1.2, 1.1, 1.5],  # t+3
    Date.new(2017, 6, 30) => [1.1, 1.2, 1.3, 1.4, 1.0],
    Date.new(2017, 8, 31) => [1.8, 1.6, 1.4, 1.2, 2.0],  # t+6
    Date.new(2018, 2, 28) => [2.0, 1.5, 1.2, 1.1, 2.5]   # t+12
  }.freeze

  setup do
    teardown_data
    NAMES.each_with_index do |(cik, ticker), i|
      UniverseMember.create!(cik: cik, ticker: ticker, name: ticker, sic: "3500", anchor_year: ANCHOR, has_prices: true)
      base = { cik: cik, ticker: ticker, fiscal_year: 2016, filed: Date.new(2017, 2, 20), form: "10-K" }
      PitFact.create!(base.merge(concept: "operating_income", period_start: Date.new(2016, 1, 1), period_end: Date.new(2016, 12, 31), value: 80.0))
      PitFact.create!(base.merge(concept: "dep_amort", period_start: Date.new(2016, 1, 1), period_end: Date.new(2016, 12, 31), value: 20.0))
      PitFact.create!(base.merge(concept: "cash", period_end: Date.new(2016, 12, 31), value: 50.0))
      PitFact.create!(base.merge(concept: "debt_noncurrent", period_end: Date.new(2016, 12, 31), value: 50.0))
      PitFact.create!(base.merge(concept: "shares_cover", period_end: Date.new(2017, 2, 10), value: 10.0))
      month = Date.new(2016, 11, 30)
      while month <= Date.new(2018, 2, 28)
        close = if month == T then CLOSES_AT_T[ticker]
                elsif month == Date.new(2017, 3, 31) then [200.0, 150.0, 100.0, 50.0, 12.5][i] # reversed: a signal read from t+1 ranks the other way
                elsif ticker == "HE" then month < Date.new(2017, 4, 30) ? 12.5 : 30.0
                else 100.0
                end
        PriceBar.create!(ticker: ticker, month_end: month, close: close, adj_close: ADJ.fetch(month, [1.0] * 5)[i], source: "synthetic")
        month = Date.new((month >> 1).year, (month >> 1).month, -1)
      end
    end
    # HA restates FY2016 operating income on T itself: public after the close, so not usable at T.
    PitFact.create!(cik: 9101, ticker: "HA", concept: "operating_income", fiscal_year: 2016, filed: T, form: "10-K/A",
                    period_start: Date.new(2016, 1, 1), period_end: Date.new(2016, 12, 31), value: 180.0)
    SplitEvent.create!(ticker: "HE", date: Date.new(2017, 4, 15), ratio: 2.0)
  end

  teardown { teardown_data }

  def teardown_data
    UniverseMember.where(cik: 9101..9110).delete_all
    PitFact.where(cik: 9101..9110).delete_all
    PriceBar.where(ticker: NAMES.values + %w[HF HG HH]).delete_all
    SplitEvent.where(ticker: NAMES.values).delete_all
    BacktestRun.where(name: "hand").delete_all
  end

  def by_ticker(rows) = rows.to_h { |r| [r.ticker, r] }

  test "multiples and signals at T are exactly the hand-computed values" do
    rows = by_ticker(Backtest::Runner.cross_section(Backtest::Runner.load(ANCHOR), T))
    # EBITDA 100, net debt 0, shares 10: multiple = close / 10. HE's stored 12.5 is a
    # post-split price for a pre-split date, so the raw close is 25 and the multiple 2.5.
    assert_equal({ "HA" => 5.0, "HB" => 10.0, "HC" => 15.0, "HD" => 20.0, "HE" => 2.5 }, rows.transform_values(&:multiple))
    assert_equal 25.0, rows["HE"].close
    assert_equal 10.0, rows["HE"].shares, "the split is after T, so the cover count is not rolled forward"
    # Leave-one-out medians: HE 12.5, HA 12.5, HB 10, HC 7.5, HD 7.5.
    expected = { "HE" => Math.log(5.0), "HA" => Math.log(2.5), "HB" => 0.0, "HC" => Math.log(0.5), "HD" => Math.log(0.375) }
    expected.each { |ticker, signal| assert_in_delta signal, rows[ticker].signal, 1e-12, ticker }
    assert_equal 100.0, rows["HA"].ebitda, "the restatement filed on T is not public at T's close"
  end

  test "a filing dated T is used from the next month-end" do
    data = Backtest::Runner.load(ANCHOR)
    assert_equal 200.0, by_ticker(Backtest::Runner.cross_section(data, Date.new(2017, 3, 31)))["HA"].ebitda
  end

  test "the forward return is measured from T to exactly T plus the horizon on adjusted closes" do
    results = Backtest::Runner.run!(name: "hand", anchor_year: ANCHOR, min_names: 3, persist: false)
    assert_equal [T.iso8601], results[:coverage].select { |c| c[:names_with_signal].positive? }.map { |c| c[:date] }
    [3, 6, 12].each do |h|
      r = results[:horizons][h]
      assert_equal 1, r[:n_dates], "horizon #{h}"
      assert_equal 1.0, r[:mean_ic], "horizon #{h}: only the true forward window ranks like the signal"
      assert_equal 5.0, r[:avg_names]
      assert_equal 1.0, r[:hit_rate]
    end
    # 12m quintiles with five names are one name each: Q1 = HE (2.5 - 1 = 150%), Q5 = HD (10%).
    assert_in_delta 1.5, results[:horizons][12][:mean_q1_return], 1e-9
    assert_in_delta 0.1, results[:horizons][12][:mean_q5_return], 1e-9
    assert_in_delta 1.4, results[:horizons][12][:mean_spread], 1e-9
  end

  test "splits: the month of the split is skipped, then the cover count is rolled forward" do
    data = Backtest::Runner.load(ANCHOR)
    assert_nil by_ticker(Backtest::Runner.cross_section(data, Date.new(2017, 4, 30)))["HE"], "Yahoo's bar straddles the split"
    after = by_ticker(Backtest::Runner.cross_section(data, Date.new(2017, 5, 31)))["HE"]
    assert_equal 30.0, after.close, "no later split, so the stored close is the raw close"
    assert_equal 20.0, after.shares, "10 cover-page shares filed 20 Feb, doubled by the 15 April split"
    assert_in_delta 6.0, after.multiple, 1e-12 # 30 x 20 / 100
  end

  test "a name with a zero cover count, or cash but no debt line, is excluded; a total-debt tag is enough" do
    extra = { 9106 => "HF", 9107 => "HG", 9108 => "HH" }
    extra.each do |cik, ticker|
      UniverseMember.create!(cik: cik, ticker: ticker, name: ticker, sic: "3500", anchor_year: ANCHOR, has_prices: true)
      base = { cik: cik, ticker: ticker, fiscal_year: 2016, filed: Date.new(2017, 2, 20), form: "10-K" }
      PitFact.create!(base.merge(concept: "operating_income", period_start: Date.new(2016, 1, 1), period_end: Date.new(2016, 12, 31), value: 80.0))
      PitFact.create!(base.merge(concept: "dep_amort", period_start: Date.new(2016, 1, 1), period_end: Date.new(2016, 12, 31), value: 20.0))
      PitFact.create!(base.merge(concept: "cash", period_end: Date.new(2016, 12, 31), value: 50.0))
      PitFact.create!(base.merge(concept: "shares_cover", period_end: Date.new(2017, 2, 10), value: ticker == "HF" ? 0.0 : 10.0))
      PriceBar.create!(ticker: ticker, month_end: T, close: 100.0, adj_close: 1.0, source: "synthetic")
    end
    PitFact.create!(cik: 9106, ticker: "HF", concept: "debt_noncurrent", fiscal_year: 2016, filed: Date.new(2017, 2, 20), form: "10-K", period_end: Date.new(2016, 12, 31), value: 50.0)
    PitFact.create!(cik: 9108, ticker: "HH", concept: "debt_total", fiscal_year: 2016, filed: Date.new(2017, 2, 20), form: "10-K", period_end: Date.new(2016, 12, 31), value: 250.0)

    counters = Hash.new(0)
    rows = by_ticker(Backtest::Runner.cross_section(Backtest::Runner.load(ANCHOR), T, counters: counters))
    assert_nil rows["HF"], "zero shares: a bond or preferred ticker"
    assert_nil rows["HG"], "cash known, no debt line: unknown, not debt-free"
    assert_equal 1, counters[:non_positive_shares]
    assert_equal 1, counters[:no_debt_line]
    assert_equal 200.0, rows["HH"].net_debt # 250 total debt - 50 cash
    assert_in_delta 12.0, rows["HH"].multiple, 1e-12 # (100 x 10 + 200) / 100
  ensure
    PitFact.where(cik: extra.keys).delete_all
    UniverseMember.where(cik: extra.keys).delete_all
    PriceBar.where(ticker: extra.values).delete_all
  end
end
