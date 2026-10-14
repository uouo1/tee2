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
