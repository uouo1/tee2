# frozen_string_literal: true

module Backtest
  # Monthly, point-in-time, cross-sectional evaluation of the comps signal
  # (docs/BACKTEST.md, "Method"). Nothing here reads a value filed after the
  # date it is standing on.
  module Runner
    HORIZONS = [3, 6, 12].freeze
    STALE_MONTHS = 18
    MIN_NAMES = 20
    MAX_MULTIPLE = 200.0
    MIN_PEERS = 8

    Observation = Struct.new(:cik, :ticker, :sic2, :close, :adj_close, :shares, :ebitda, :net_debt,
                             :multiple, :signal, :peer_group, keyword_init: true)

    module_function

    def run!(name:, anchor_year: 2016, horizons: HORIZONS, min_peers: MIN_PEERS, persist: true)
      data = load(anchor_year)
      dates = month_ends(data, horizons.max)
      panel = dates.map { |t| [t, cross_section(data, t, min_peers: min_peers)] }
      horizon_results = horizons.to_h { |h| [h, evaluate(panel, data, h)] }

      results = {
        params: { anchor_year: anchor_year, horizons: horizons, min_peers: min_peers,
                  stale_months: STALE_MONTHS, min_names: MIN_NAMES, signal: "ln(peer median EV/EBITDA / own EV/EBITDA)" },
        universe: Universe.summary(anchor_year).merge(
          priced: data[:members].size,
          no_price_history: UniverseMember.where(anchor_year: anchor_year, dropout_reason: "no_price_history").count
        ),
        data: {
          pit_fact_rows: PitFact.where(cik: data[:members].map(&:cik)).count,
          price_bars: PriceBar.where(ticker: data[:members].map(&:ticker)).count,
          unadjusted_bars: PriceBar.where(ticker: data[:members].map(&:ticker), adjusted: false).count
        },
        dates: { first: dates.first&.iso8601, last: dates.last&.iso8601, count: dates.size },
        coverage: panel.map { |t, rows| { date: t.iso8601, names_with_signal: rows.size } },
        horizons: horizon_results,
        biases: BIASES
      }
      return results unless persist

      run = BacktestRun.create!(name: name, params: JSON.generate(results[:params]), results: JSON.generate(results))
      run
    end

    BIASES = [
      "Survivorship in the price leg: members without a current ticker or price history are excluded from returns; their counts are in `universe`.",
      "Point-in-time: only facts with filed <= t are used, so restatements are not seen before they existed.",
      "Fiscal-year lag: annual figures become usable on their filing date, not at period end; figures older than #{STALE_MONTHS} months are not used.",
      "Share counts are the latest cover-page figure known at t.",
      "Unadjusted Nasdaq fallback bars understate total return; their count is in `data.unadjusted_bars`.",
      "Top-N by revenue tilts the universe large; the median anchor revenue is reported.",
      "No transaction costs, no shorting, no sector neutralisation beyond the peer-group signal."
    ].freeze

    # ---------------------------------------------------------------- data

    def load(anchor_year)
      members = UniverseMember.for_anchor(anchor_year).priced.where.not(ticker: nil).to_a
      tickers = members.map(&:ticker)
      ciks = members.map(&:cik)

      prices = Hash.new { |h, k| h[k] = {} }
      PriceBar.where(ticker: tickers).pluck(:ticker, :month_end, :close, :adj_close).each do |ticker, month_end, close, adj|
        prices[ticker][month_end] = [close, adj]
      end

      facts = Hash.new { |h, k| h[k] = Hash.new { |hh, kk| hh[kk] = [] } }
      concepts = %w[operating_income dep_amort cash short_term_investments debt_current debt_noncurrent shares_cover]
      PitFact.where(cik: ciks, concept: concepts).order(:filed)
             .pluck(:cik, :concept, :period_end, :filed, :value, :form).each do |cik, concept, period_end, filed, value, form|
        next if %w[operating_income dep_amort].include?(concept) && !form.to_s.start_with?("10-K")

        facts[cik][concept] << [period_end, filed, value]
      end
      { members: members, prices: prices, facts: facts }
    end

    def month_ends(data, max_horizon)
      all = data[:prices].values.flat_map(&:keys).uniq.sort
      return [] if all.empty?

      last_usable = shift_months(all.last, -max_horizon)
      all.select { |d| d >= Date.new(data[:members].first&.anchor_year.to_i + 1, 1, 31) && d <= last_usable }
    end

    def shift_months(date, months)
      moved = date >> months
      Date.new(moved.year, moved.month, -1)
    end

    # Latest value known on `as_of` whose period end is recent enough.
    def known(rows, as_of, min_period_end)
      best = nil
      rows.each do |period_end, filed, value|
        break if filed > as_of # rows are sorted by filed
        next if period_end < min_period_end

        best = [period_end, filed, value] if best.nil? || ([period_end, filed] <=> [best[0], best[1]]) == 1
      end
      best && best[2]
    end

    # ------------------------------------------------------------ signal

    def cross_section(data, t, min_peers: MIN_PEERS)
      floor = shift_months(t, -STALE_MONTHS)
      rows = []
      data[:members].each do |m|
        bar = data[:prices][m.ticker][t]
        next unless bar && bar[0].to_f.positive?

        f = data[:facts][m.cik]
        shares = known(f["shares_cover"], t, floor)
        oi = known(f["operating_income"], t, floor)
        da = known(f["dep_amort"], t, floor)
        cash = known(f["cash"], t, floor)
        debt_c = known(f["debt_current"], t, floor)
        debt_nc = known(f["debt_noncurrent"], t, floor)
        sti = known(f["short_term_investments"], t, floor)
        next if shares.nil? || oi.nil? || da.nil?
        next if cash.nil? && debt_c.nil? && debt_nc.nil? # unknown net debt is unknown, not zero

        ebitda = oi + da
        next unless ebitda.positive?

        net_debt = (debt_c || 0) + (debt_nc || 0) - (cash || 0) - (sti || 0)
        ev = bar[0] * shares + net_debt
        multiple = ev / ebitda
        next unless multiple.positive? && multiple < MAX_MULTIPLE

        rows << Observation.new(cik: m.cik, ticker: m.ticker, sic2: m.sic.to_s[0, 2].presence || "??",
                                close: bar[0], adj_close: bar[1], shares: shares, ebitda: ebitda,
                                net_debt: net_debt, multiple: multiple)
      end
      assign_signals(rows, min_peers)
    end

    # Peer group = 2-digit SIC when it has enough names, else the whole
    # cross-section; signal = ln(peer median / own), leave-one-out.
    def assign_signals(rows, min_peers)
      groups = rows.group_by(&:sic2)
      rows.each do |row|
        peers = groups[row.sic2]
        if peers.size < min_peers
          peers = rows
          row.peer_group = "ALL"
        else
          row.peer_group = row.sic2
        end
        others = peers.reject { |p| p.equal?(row) }.map(&:multiple)
        next if others.size < 2

        row.signal = Math.log(Stats.median(others) / row.multiple)
      end
      rows.select(&:signal)
    end

    # --------------------------------------------------------- evaluation

    def evaluate(panel, data, horizon)
      ics = []
      spreads = []
      q1s = []
      q5s = []
      benchmarks = []
      names = []
      dropped_no_forward = 0
      series = []
      panel.each do |t, rows|
        t_h = shift_months(t, horizon)
        pairs = rows.filter_map do |row|
          fwd_bar = data[:prices][row.ticker][t_h]
          if fwd_bar.nil? || row.adj_close.to_f <= 0
            dropped_no_forward += 1
            next
          end
          [row.signal, fwd_bar[1] / row.adj_close - 1.0]
        end
        next if pairs.size < MIN_NAMES

        signals = pairs.map(&:first)
        returns = pairs.map(&:last)
        ic = Stats.spearman(signals, returns)
        next if ic.nil?

        quintiles = Stats.quintile_means(signals, returns)
        ics << ic
        q1s << quintiles.first
        q5s << quintiles.last
        spreads << (quintiles.first - quintiles.last)
        benchmarks << Stats.mean(returns)
        names << pairs.size
        series << { date: t.iso8601, ic: ic.round(4), spread: (quintiles.first - quintiles.last).round(4), names: pairs.size }
      end
      return { n_dates: 0 } if ics.empty?

      annualise = ->(r) { ((1 + r)**(12.0 / horizon)) - 1 }
      {
        n_dates: ics.size,
        mean_ic: Stats.mean(ics).round(4),
        sd_ic: Stats.stddev(ics)&.round(4),
        t_newey_west: Stats.newey_west_t(ics, lags: horizon - 1)&.round(2),
        hit_rate: (ics.count(&:positive?) / ics.size.to_f).round(3),
        avg_names: Stats.mean(names).round(1),
        mean_q1_return: Stats.mean(q1s).round(4),
        mean_q5_return: Stats.mean(q5s).round(4),
        mean_spread: Stats.mean(spreads).round(4),
        spread_annualised: annualise.call(Stats.mean(spreads)).round(4),
        benchmark_mean_return: Stats.mean(benchmarks).round(4),
        benchmark_annualised: annualise.call(Stats.mean(benchmarks)).round(4),
        dropped_no_forward_price: dropped_no_forward,
        series: series
      }
    end
  end
end
