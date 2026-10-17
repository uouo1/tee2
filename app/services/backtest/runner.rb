# frozen_string_literal: true

module Backtest
  # Monthly, point-in-time, cross-sectional evaluation of the comps signal
  # (docs/BACKTEST.md, "Method"). Nothing here reads a value filed on or after
  # the date it is standing on.
  module Runner
    HORIZONS = [3, 6, 12].freeze
    STALE_MONTHS = 18
    MIN_NAMES = 20
    MAX_MULTIPLE = 200.0
    MIN_PEERS = 8

    Observation = Struct.new(:cik, :ticker, :sic2, :close, :adj_close, :shares, :ebitda, :net_debt,
                             :multiple, :signal, :peer_group, :ebitda_period_end, :dep_amort_period_end,
                             keyword_init: true)

    # The construction rules, printed with every result so a reader of the
    # report does not have to open the code.
    RULES = [
      "A fact is known from the day after it was filed (filed < t), never on its filing date.",
      "Operating income and D&A come from 10-K rows only; cash, investments, debt and the cover-page share count from the latest filing of any form.",
      "Inputs older than #{STALE_MONTHS} months are not used.",
      "Market cap = unadjusted close × cover-page shares: Yahoo's split-adjusted close is multiplied back by every split after t, the share count is rolled forward through splits between its filing date and t, and a name is skipped in a month that contains a split.",
      "A share count of zero or less (a bond or preferred ticker) excludes the name.",
      "Net debt needs a known cash line and a known debt line (current or non-current, else a total-debt tag); a name with cash but no debt line is excluded rather than treated as debt-free.",
      "EBITDA must be positive and 0 < EV/EBITDA < #{MAX_MULTIPLE.to_i}.",
      "Peer group is the 2-digit SIC when it has at least #{MIN_PEERS} names with a multiple, otherwise the whole cross-section; the signal is ln(median of the OTHER names' multiples / own multiple).",
      "Forward return = adj_close(t+h) / adj_close(t) − 1; a date needs at least #{MIN_NAMES} names."
    ].freeze

    module_function

    def run!(name:, anchor_year: 2016, horizons: HORIZONS, min_peers: MIN_PEERS, min_names: MIN_NAMES, persist: true)
      data = load(anchor_year)
      dates = month_ends(data, horizons.max)
      counters = Hash.new(0)
      panel = dates.map { |t| [t, cross_section(data, t, min_peers: min_peers, counters: counters)] }
      horizon_results = horizons.to_h { |h| [h, evaluate(panel, data, h, min_names: min_names)] }

      members = UniverseMember.where(anchor_year: anchor_year)
      results = {
        params: { anchor_year: anchor_year, horizons: horizons, min_peers: min_peers, min_names: min_names,
                  stale_months: STALE_MONTHS, signal: "ln(peer median EV/EBITDA / own EV/EBITDA)" },
        rules: RULES,
        universe: Universe.summary(anchor_year).merge(
          priced: data[:members].size,
          no_price_history: members.where(dropout_reason: "no_price_history").count,
          not_a_filer_in_anchor_year: members.where(dropout_reason: "not_a_filer_in_anchor_year").count
        ),
        data: {
          pit_fact_rows: PitFact.where(cik: data[:members].map(&:cik)).count,
          price_bars: PriceBar.where(ticker: data[:members].map(&:ticker)).count,
          unadjusted_bars: PriceBar.where(ticker: data[:members].map(&:ticker), adjusted: false).count,
          split_events: SplitEvent.where(ticker: data[:members].map(&:ticker)).count,
          names_ever_with_signal: panel.flat_map { |_t, rows| rows.map(&:cik) }.uniq.size
        },
        exclusions: counters.sort.to_h,
        dates: { first: dates.first&.iso8601, last: dates.last&.iso8601, count: dates.size },
        coverage: panel.map { |t, rows| { date: t.iso8601, names_with_signal: rows.size } },
        horizons: horizon_results,
        biases: BIASES
      }
      return results unless persist

      BacktestRun.create!(name: name, params: JSON.generate(results[:params]), results: JSON.generate(results))
    end

    BIASES = [
      "Survivorship in the price leg: only members with a current ticker that Yahoo still serves have returns. `no_current_ticker` is an upper bound on delistings, not a clean count: it also holds debt-only subsidiaries, predecessor CIKs and registrants whose ticker now maps to a new CIK (Exxon Mobil). Forward prices are never missing for a priced name, which is the same fact seen from the other side.",
      "Universe selection: the revenue frame that ranks the anchor year carries no filing date and mostly holds values filed two to four years later as restated comparatives, so the ranking is not strictly point-in-time. Members with no filing before mid-way through the following year are dropped as `not_a_filer_in_anchor_year` and counted.",
      "Point-in-time: only facts with filed < t are used, so restatements are not seen before they existed and nothing filed on t is used at t's close.",
      "Fiscal-year lag: annual figures become usable on their filing date, not at period end; figures older than #{STALE_MONTHS} months are not used. Operating income and D&A can come from different fiscal years when the newer 10-K lacks a D&A tag (counted in `exclusions`/`data`), and balance-sheet items from a newer 10-Q than the P&L.",
      "Share counts are the cover-page figure known at t, rolled forward through splits; between filings the last known count is used.",
      "Instrument mapping: the first-listed SEC ticker is taken as the common stock; names whose cover-page count is zero or negative (bonds, preferreds, cooperatives) are excluded.",
      "Names with a cash line but no debt line are excluded, not treated as debt-free; names with neither are excluded too. Both choices shrink the cross-section.",
      "Unadjusted Nasdaq fallback bars understate total return; their count is in `data.unadjusted_bars`.",
      "Top-N by revenue tilts the universe large; the median anchor revenue is reported.",
      "No transaction costs, no shorting, no sector neutralisation beyond the peer-group signal; the result says whether the signal ranks, not whether it could be harvested."
    ].freeze

    # ---------------------------------------------------------------- data

    def load(anchor_year)
      members = UniverseMember.for_anchor(anchor_year).priced.where(dropout_reason: nil).where.not(ticker: nil).to_a
      tickers = members.map(&:ticker)
      ciks = members.map(&:cik)

      prices = Hash.new { |h, k| h[k] = {} }
      PriceBar.where(ticker: tickers).pluck(:ticker, :month_end, :close, :adj_close).each do |ticker, month_end, close, adj|
        prices[ticker][month_end] = [close, adj]
      end

      splits = Hash.new { |h, k| h[k] = [] }
      SplitEvent.where(ticker: tickers).order(:date).pluck(:ticker, :date, :ratio).each do |ticker, date, ratio|
        splits[ticker] << [date, ratio.to_f]
      end

      facts = Hash.new { |h, k| h[k] = Hash.new { |hh, kk| hh[kk] = [] } }
      concepts = %w[operating_income dep_amort cash short_term_investments debt_current debt_noncurrent debt_total shares_cover]
      PitFact.where(cik: ciks, concept: concepts).order(:filed)
             .pluck(:cik, :concept, :period_end, :filed, :value, :form).each do |cik, concept, period_end, filed, value, form|
        next if %w[operating_income dep_amort].include?(concept) && !form.to_s.start_with?("10-K")

        facts[cik][concept] << [period_end, filed, value]
      end
      { members: members, prices: prices, facts: facts, splits: splits }
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

    # Latest observation known on `as_of` (filed strictly before it) whose
    # period end is recent enough, as [period_end, filed, value]; nil if none.
    def known(rows, as_of, min_period_end)
      best = nil
      rows.each do |period_end, filed, value|
        break if filed >= as_of # rows are sorted by filed; a filing dated t is public after t's close
        next if period_end < min_period_end

        best = [period_end, filed, value] if best.nil? || ([period_end, filed] <=> [best[0], best[1]]) == 1
      end
      best
    end

    # Product of the split ratios dated after `after` and, when given, on or
    # before `upto`.
    def split_factor(splits, after, upto = nil)
      splits.reduce(1.0) do |factor, (date, ratio)|
        date > after && (upto.nil? || date <= upto) ? factor * ratio : factor
      end
    end

    def split_in_month?(splits, month_end)
      first = Date.new(month_end.year, month_end.month, 1)
      splits.any? { |date, _ratio| date >= first && date <= month_end }
    end

    # ------------------------------------------------------------ signal

    def cross_section(data, t, min_peers: MIN_PEERS, counters: Hash.new(0))
      floor = shift_months(t, -STALE_MONTHS)
      rows = []
      data[:members].each do |m|
        bar = data[:prices][m.ticker][t]
        next counters[:no_price] += 1 unless bar && bar[0].to_f.positive?

        splits = data[:splits][m.ticker]
        next counters[:split_in_month] += 1 if split_in_month?(splits, t)

        f = data[:facts][m.cik]
        shares_row = known(f["shares_cover"], t, floor)
        next counters[:no_shares] += 1 if shares_row.nil?
        next counters[:non_positive_shares] += 1 unless shares_row[2].positive?

        oi = known(f["operating_income"], t, floor)
        da = known(f["dep_amort"], t, floor)
        next counters[:no_operating_income] += 1 if oi.nil?
        next counters[:no_dep_amort] += 1 if da.nil?

        cash = known(f["cash"], t, floor)
        sti = known(f["short_term_investments"], t, floor)
        debt_c = known(f["debt_current"], t, floor)
        debt_nc = known(f["debt_noncurrent"], t, floor)
        debt_total = known(f["debt_total"], t, floor)
        next counters[:no_cash] += 1 if cash.nil?

        gross_debt =
          if debt_c || debt_nc
            (debt_c ? debt_c[2] : 0.0) + (debt_nc ? debt_nc[2] : 0.0)
          elsif debt_total
            debt_total[2]
          end
        next counters[:no_debt_line] += 1 if gross_debt.nil? # cash without a debt line is unknown, not zero

        ebitda = oi[2] + da[2]
        next counters[:non_positive_ebitda] += 1 unless ebitda.positive?

        counters[:ebitda_mixed_periods] += 1 if oi[0] != da[0]
        # Undo Yahoo's split adjustment of bars before later splits; roll the
        # cover count forward through splits between its filing and t.
        close = bar[0] * split_factor(splits, t)
        shares = shares_row[2] * split_factor(splits, shares_row[1], t)
        net_debt = gross_debt - cash[2] - (sti ? sti[2] : 0.0)
        ev = close * shares + net_debt
        multiple = ev / ebitda
        next counters[:multiple_out_of_range] += 1 unless multiple.positive? && multiple < MAX_MULTIPLE

        rows << Observation.new(cik: m.cik, ticker: m.ticker, sic2: m.sic.to_s[0, 2].presence || "??",
                                close: close, adj_close: bar[1], shares: shares, ebitda: ebitda,
                                net_debt: net_debt, multiple: multiple,
                                ebitda_period_end: oi[0], dep_amort_period_end: da[0])
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

    def evaluate(panel, data, horizon, min_names: MIN_NAMES)
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
        next if pairs.size < min_names

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
        t_spread_newey_west: Stats.newey_west_t(spreads, lags: horizon - 1)&.round(2),
        spread_hit_rate: (spreads.count(&:positive?) / spreads.size.to_f).round(3),
        benchmark_mean_return: Stats.mean(benchmarks).round(4),
        benchmark_annualised: annualise.call(Stats.mean(benchmarks)).round(4),
        dropped_no_forward_price: dropped_no_forward,
        series: series
      }
    end
  end
end
