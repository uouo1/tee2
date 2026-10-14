# frozen_string_literal: true

# Valuation mechanics: trading comps, precedent transactions, DCF, football field.
#
# The numbers here are the ones a pitch book actually argues with, so each helper
# returns its inputs alongside its outputs — a multiple without the metric it was
# applied to is unauditable, and an unauditable number does not belong in a deck.
#
# Conventions: all currency amounts are in millions of the company's reporting
# currency; per-share figures are absolute; rates are decimals (0.095 = 9.5%).
# Hashes use symbol keys; `Date`s stay `Date`s (the API boundary stringifies).
#
# Port of argos/valuation.py. `Valuation::DcfAssumptions` lives in
# valuation/dcf_assumptions.rb.
module Valuation
  MULTIPLES = %i[ev_revenue ev_ebitda pe].freeze
  MULTIPLE_LABELS = { ev_revenue: "EV / Revenue", ev_ebitda: "EV / EBITDA", pe: "P / E" }.freeze

  # Valuation defaults (argos/config.py `Config`), overridable per pitch book.
  DEFAULT_WACC = 0.095
  DEFAULT_TERMINAL_GROWTH = 0.025
  DEFAULT_TAX_RATE = 0.23
  PROJECTION_YEARS = 5

  module_function

  # ---------------------------------------------------------------- statistics

  # Linear-interpolation percentile (`pct` in [0, 1]); nil on empty input.
  def percentile(values, pct)
    clean = values.to_a.compact.sort
    return nil if clean.empty?
    return clean.first.to_f if clean.size == 1

    position = (clean.size - 1) * pct.to_f.clamp(0.0, 1.0)
    low = position.floor
    high = [low + 1, clean.size - 1].min
    weight = position - low
    (clean[low] * (1 - weight) + clean[high] * weight).to_f
  end

  def describe(values)
    clean = values.to_a.compact.map(&:to_f)
    if clean.empty?
      return { count: 0, min: nil, p25: nil, median: nil, p75: nil, max: nil, mean: nil }
    end

    {
      count: clean.size,
      min: clean.min,
      p25: percentile(clean, 0.25),
      median: percentile(clean, 0.5),
      p75: percentile(clean, 0.75),
      max: clean.max,
      mean: clean.inject(0.0, :+) / clean.size # naive left-to-right sum, as Python's sum()
    }
  end

  # ------------------------------------------------------------------ company

  # Capital structure and trading multiples for one company.
  #
  # Multiples are computed off the most recent *actual* fiscal year and off each
  # forward estimate year, because comps are only comparable when the vintage of
  # the denominator matches.
  def company_metrics(ticker, forward_years: 2)
    company = Company.find_ticker(ticker)
    return nil unless company

    market = company.market_datum
    financials = company.financials.order(:fiscal_year).map { |f| f.attributes.symbolize_keys }
    actuals = financials.reject { |f| f[:is_estimate] }
    latest = actuals.last || financials.last
    return nil if latest.nil?

    price = (market&.share_price || 0.0).to_f
    shares = (market&.shares_diluted || 0.0).to_f
    net_debt = (market&.net_debt || 0.0).to_f
    market_cap = price * shares
    enterprise_value = market_cap + net_debt

    forwards = financials.select { |f| f[:is_estimate] }.first(forward_years)
                         .map { |f| multiples_for(f, enterprise_value: enterprise_value, price: price) }
    {
      company_id: company.id,
      ticker: company.ticker,
      name: company.name,
      sector: company.sector,
      industry: company.industry,
      country: company.country,
      hq: company.hq,
      employees: company.employees,
      currency: company.currency.presence || "USD",
      description: company.description,
      as_of: market&.as_of,
      share_price: price,
      shares_diluted: shares,
      net_debt: net_debt,
      market_cap: rnd(market_cap, 1),
      enterprise_value: rnd(enterprise_value, 1),
      week52_low: market&.week52_low,
      week52_high: market&.week52_high,
      beta: market&.beta,
      latest_actual: multiples_for(latest, enterprise_value: enterprise_value, price: price),
      forward: forwards,
      financials: financials
    }
  end

  # -------------------------------------------------------------- trading comps

  # Comparable companies table plus the distribution of each multiple.
  def comps_table(tickers, exclude: nil)
    rows = []
    Array(tickers).each do |ticker|
      next if exclude && ticker.to_s.upcase == exclude.to_s.upcase

      metrics = company_metrics(ticker)
      next unless metrics

      latest = metrics[:latest_actual]
      rows << {
        ticker: metrics[:ticker],
        name: metrics[:name],
        country: metrics[:country],
        share_price: metrics[:share_price],
        market_cap: metrics[:market_cap],
        enterprise_value: metrics[:enterprise_value],
        net_debt: metrics[:net_debt],
        revenue: rnd(latest[:revenue], 1),
        ebitda: rnd(latest[:ebitda], 1),
        ebitda_margin: latest[:ebitda_margin],
        ev_revenue: latest[:ev_revenue],
        ev_ebitda: latest[:ev_ebitda],
        pe: latest[:pe],
        fiscal_year: latest[:fiscal_year]
      }
    end
    # Largest first. Python's sort is stable; Ruby's sort_by is not, so the
    # original index breaks ties the same way.
    rows = rows.each_with_index.sort_by { |row, index| [-(row[:enterprise_value] || 0), index] }.map(&:first)
    stats = MULTIPLES.to_h { |m| [m, round_stats(describe(rows.map { |r| r[m] }))] }
    { rows: rows, stats: stats, labels: MULTIPLE_LABELS }
  end

  # Precedent M&A transactions with multiple and premium distributions.
  def precedent_transactions(sector: nil)
    scope = Transaction.newest_first
    scope = scope.where(sector: sector) if sector.present?
    rows = scope.map { |t| t.attributes.symbolize_keys }
    stats = {
      ev_revenue: round_stats(describe(rows.map { |r| r[:ev_revenue] })),
      ev_ebitda: round_stats(describe(rows.map { |r| r[:ev_ebitda] })),
      premium_1day: round_stats(describe(rows.map { |r| r[:premium_1day] }), 3)
    }
    { rows: rows, stats: stats }
  end

  # ----------------------------------------------------------- implied values

  # Translate a multiple range into an implied share-price range.
  #
  # `kind` is "ev" (bridge through net debt) or "equity" (already a per-share
  # earnings multiple).
  def implied_from_multiple(multiple_low, multiple_high, metric_value:, kind:, net_debt:, shares:)
    return nil if !number?(shares) || multiple_low.nil? || multiple_high.nil? || !number?(metric_value)

    low_m, high_m = [multiple_low.to_f, multiple_high.to_f].sort
    metric_value = metric_value.to_f
    per_share = lambda do |multiple|
      if kind.to_s == "ev"
        (multiple * metric_value - net_debt.to_f) / shares.to_f
      else
        multiple * metric_value
      end
    end

    low, high = [per_share.call(low_m), per_share.call(high_m)].sort
    {
      low: rnd(low, 2),
      high: rnd(high, 2),
      mid: rnd((low + high) / 2, 2),
      multiple_low: rnd(low_m, 2),
      multiple_high: rnd(high_m, 2),
      metric_value: rnd(metric_value, 1)
    }
  end

  # -------------------------------------------------------------------- DCF

  # Project unlevered free cash flow, discount it, and bridge to per share.
  #
  # Takes a DcfAssumptions (or a partial hash, coerced the same way the API
  # payload is). Invalid inputs raise ArgumentError.
  def run_dcf(assumptions)
    a = to_assumptions(assumptions)
    raise ArgumentError, "wacc must be positive" if a.wacc <= 0
    raise ArgumentError, "base_revenue must be positive" if a.base_revenue <= 0
    raise ArgumentError, "years must be positive" if a.years < 1
    if a.exit_multiple.nil? && a.terminal_growth >= a.wacc
      raise ArgumentError, "terminal growth must be below WACC when using a growth-based terminal value"
    end

    projections = []
    revenue = a.base_revenue.to_f
    growth = a.revenue_growth.to_f
    margin = a.ebitda_margin.to_f
    pv_total = 0.0

    (1..a.years).each do |index|
      revenue *= (1 + growth)
      margin += a.margin_expansion
      ebitda = revenue * margin
      dep_amort = revenue * a.da_pct_revenue
      ebit = ebitda - dep_amort
      taxes = [0.0, ebit].max * a.tax_rate
      capex = revenue * a.capex_pct_revenue
      nwc = revenue * a.nwc_pct_revenue
      fcf = ebit - taxes + dep_amort - capex - nwc
      period = a.mid_year_convention ? index - 0.5 : index
      discount = 1.0 / ((1 + a.wacc.to_f)**period)
      pv = fcf * discount
      pv_total += pv
      projections << {
        year: a.start_year + index - 1,
        revenue: rnd(revenue, 1),
        growth: rnd(growth, 4),
        ebitda: rnd(ebitda, 1),
        ebitda_margin: rnd(margin, 4),
        ebit: rnd(ebit, 1),
        taxes: rnd(taxes, 1),
        dep_amort: rnd(dep_amort, 1),
        capex: rnd(capex, 1),
        nwc_change: rnd(nwc, 1),
        fcf: rnd(fcf, 1),
        discount_factor: rnd(discount, 4),
        pv_fcf: rnd(pv, 1)
      }
      growth = [a.terminal_growth.to_f, growth * (1 - a.growth_fade)].max
    end

    # The terminal year builds on the *rounded* projection figures, as the
    # reference does, so the table and the bridge agree to the displayed digit.
    terminal_fcf = projections.last[:fcf] * (1 + a.terminal_growth)
    if a.exit_multiple.nil?
      terminal_value = terminal_fcf / (a.wacc - a.terminal_growth)
      terminal_method = format("Gordon growth at %.1f%%", a.terminal_growth * 100)
    else
      terminal_value = a.exit_multiple * projections.last[:ebitda]
      terminal_method = format("%.1fx exit EBITDA multiple", a.exit_multiple)
    end
    terminal_period = a.mid_year_convention ? a.years - 0.5 : a.years
    pv_terminal = terminal_value / ((1 + a.wacc.to_f)**terminal_period)

    enterprise_value = pv_total + pv_terminal
    equity_value = enterprise_value - a.net_debt.to_f
    per_share = number?(a.shares_diluted) ? equity_value / a.shares_diluted.to_f : nil
    first_ebitda = projections.first[:ebitda]

    {
      assumptions: a.to_h,
      projections: projections,
      pv_explicit: rnd(pv_total, 1),
      terminal_value: rnd(terminal_value, 1),
      pv_terminal: rnd(pv_terminal, 1),
      terminal_method: terminal_method,
      terminal_share_of_ev: number?(enterprise_value) ? rnd(pv_terminal / enterprise_value, 4) : nil,
      enterprise_value: rnd(enterprise_value, 1),
      net_debt: rnd(a.net_debt.to_f, 1),
      equity_value: rnd(equity_value, 1),
      value_per_share: per_share.nil? ? nil : rnd(per_share, 2),
      implied_ev_ebitda: number?(first_ebitda) ? rnd(enterprise_value / first_ebitda, 2) : nil
    }
  end

  # Per-share value across a WACC x terminal-growth grid.
  def dcf_sensitivity(assumptions, wacc_steps: nil, terminal_steps: nil)
    a = to_assumptions(assumptions)
    waccs = (wacc_steps.presence || [-0.015, -0.0075, 0.0, 0.0075, 0.015].map { |d| a.wacc + d }).to_a
    growths = (terminal_steps.presence || [-0.01, -0.005, 0.0, 0.005, 0.01].map { |d| a.terminal_growth + d }).to_a
    grid = growths.map do |growth|
      waccs.map do |wacc|
        trial = a.with_overrides(wacc: wacc, terminal_growth: growth)
        begin
          run_dcf(trial)[:value_per_share]
        rescue ArgumentError
          # A corner of the grid where growth >= WACC has no finite value; the
          # cell stays blank rather than poisoning the min/max.
          nil
        end
      end
    end
    flat = grid.flatten.compact
    {
      wacc_axis: waccs.map { |w| rnd(w, 4) },
      terminal_axis: growths.map { |g| rnd(g, 4) },
      grid: grid,
      min: flat.min,
      max: flat.max
    }
  end

  # ----------------------------------------------------------- football field

  # Assemble every valuation methodology into one comparable set of ranges.
  #
  # Each range is expressed per share so the methodologies can be read against
  # the current share price on a single axis — the whole point of the chart.
  def football_field(target_ticker, comp_tickers, assumptions: nil)
    target = company_metrics(target_ticker)
    raise ArgumentError, "unknown ticker: #{target_ticker}" unless target

    latest = target[:latest_actual]
    net_debt = target[:net_debt]
    shares = target[:shares_diluted]
    comps = comps_table(comp_tickers, exclude: target_ticker)
    precedents = precedent_transactions(sector: target[:sector])
    ranges = []

    comp_ebitda = comps[:stats][:ev_ebitda]
    implied = implied_from_multiple(
      comp_ebitda[:p25], comp_ebitda[:p75],
      metric_value: latest[:ebitda], kind: "ev", net_debt: net_debt, shares: shares
    )
    if implied
      ranges << valuation_range(
        "Trading comps — EV/EBITDA", implied[:low], implied[:high],
        basis: "#{implied[:multiple_low]}x–#{implied[:multiple_high]}x on FY#{latest[:fiscal_year]} " \
               "EBITDA of #{format('%.0f', implied[:metric_value])}",
        detail: implied
      )
    end

    comp_revenue = comps[:stats][:ev_revenue]
    implied = implied_from_multiple(
      comp_revenue[:p25], comp_revenue[:p75],
      metric_value: latest[:revenue], kind: "ev", net_debt: net_debt, shares: shares
    )
    if implied
      ranges << valuation_range(
        "Trading comps — EV/Revenue", implied[:low], implied[:high],
        basis: "#{implied[:multiple_low]}x–#{implied[:multiple_high]}x on FY#{latest[:fiscal_year]} " \
               "revenue of #{format('%.0f', implied[:metric_value])}",
        detail: implied
      )
    end

    # With no precedent deals the quartiles are nil and no bar is drawn: a
    # precedent range can only come from real transactions, never a placeholder.
    precedent_ebitda = precedents[:stats][:ev_ebitda]
    implied = implied_from_multiple(
      precedent_ebitda[:p25], precedent_ebitda[:p75],
      metric_value: latest[:ebitda], kind: "ev", net_debt: net_debt, shares: shares
    )
    if implied
      ranges << valuation_range(
        "Precedent transactions — EV/EBITDA", implied[:low], implied[:high],
        basis: "#{implied[:multiple_low]}x–#{implied[:multiple_high]}x on FY#{latest[:fiscal_year]} " \
               "EBITDA (#{precedent_ebitda[:count]} deals)",
        detail: implied
      )
    end

    dcf_assumptions = default_assumptions(target)
    dcf_assumptions = dcf_assumptions.with_overrides(assumptions) if assumptions.present?
    base = run_dcf(dcf_assumptions)
    # The displayed sensitivity table is deliberately wider than the band that
    # feeds the football field: the chart should show a defensible range, not the
    # extremes of a grid.
    sensitivity = dcf_sensitivity(dcf_assumptions)
    band = dcf_sensitivity(
      dcf_assumptions,
      wacc_steps: [-0.01, 0.0, 0.01].map { |d| dcf_assumptions.wacc + d },
      terminal_steps: [-0.005, 0.0, 0.005].map { |d| dcf_assumptions.terminal_growth + d }
    )
    unless band[:min].nil?
      ranges << valuation_range(
        "DCF", band[:min], band[:max],
        basis: format(
          "WACC %.2f%% ±100bps, terminal growth %.2f%% ±50bps",
          dcf_assumptions.wacc * 100, dcf_assumptions.terminal_growth * 100
        ),
        detail: { base_case: base[:value_per_share] }
      )
    end

    if number?(target[:week52_low]) && number?(target[:week52_high])
      ranges << valuation_range(
        "52-week trading range", target[:week52_low].to_f, target[:week52_high].to_f,
        basis: "Last twelve months of trading"
      )
    end

    lows = ranges.map { |r| r[:low] }
    highs = ranges.map { |r| r[:high] }
    {
      target: {
        ticker: target[:ticker], name: target[:name], share_price: target[:share_price],
        shares_diluted: shares, net_debt: net_debt, currency: target[:currency],
        market_cap: target[:market_cap], enterprise_value: target[:enterprise_value]
      },
      ranges: ranges,
      axis: {
        min: lows.empty? ? 0 : rnd(lows.min * 0.9, 2),
        max: highs.empty? ? 0 : rnd(highs.max * 1.05, 2)
      },
      reference_price: target[:share_price],
      comps: comps,
      precedents: precedents,
      dcf: base,
      sensitivity: sensitivity,
      # Median low to median high: the interquartile version let whichever
      # methodology had the widest band dictate the conclusion.
      concluded_range: {
        low: rnd(percentile(lows, 0.5) || 0, 2),
        high: rnd(percentile(highs, 0.5) || 0, 2)
      }
    }
  end

  # Seed DCF assumptions from a company's own history.
  #
  # Growth comes from the last two actual years, margin and capex intensity from
  # the latest actual, working-capital intensity from a three-year average
  # (a single year's swing is noise), and the tax rate is held to a normalised
  # band because one year's effective rate is not a forecast.
  def default_assumptions(metrics)
    financials = metrics[:financials] || []
    actuals = financials.reject { |f| f[:is_estimate] }
    latest = actuals.last || financials.last || {}
    revenue = (latest[:revenue] || 0.0).to_f
    ebitda = (latest[:ebitda] || 0.0).to_f

    growth = 0.10
    prior_revenue = actuals.size >= 2 ? actuals[-2][:revenue] : nil
    growth = (revenue / prior_revenue.to_f - 1).clamp(-0.1, 0.45) if number?(prior_revenue)

    nwc_ratios = actuals.last(3).filter_map do |f|
      f[:nwc_change].to_f / f[:revenue].to_f if !f[:nwc_change].nil? && number?(f[:revenue])
    end
    nwc_pct = nwc_ratios.empty? ? 0.012 : nwc_ratios.inject(0.0, :+) / nwc_ratios.size
    nwc_pct = nwc_pct.clamp(-0.03, 0.05)

    filed_tax = latest[:tax_rate]
    tax_rate = filed_tax.nil? ? DEFAULT_TAX_RATE : filed_tax.to_f.clamp(0.15, 0.35)

    DcfAssumptions.new(
      base_revenue: revenue,
      revenue_growth: rnd(growth, 4),
      ebitda_margin: number?(revenue) ? rnd(ebitda / revenue, 4) : 0.2,
      da_pct_revenue: number?(revenue) ? rnd((latest[:dep_amort] || 0).to_f / revenue, 4) : 0.05,
      capex_pct_revenue: number?(revenue) ? rnd((latest[:capex] || 0).to_f / revenue, 4) : 0.04,
      nwc_pct_revenue: rnd(nwc_pct, 4),
      tax_rate: rnd(tax_rate, 4),
      # Two points of WACC per unit of beta above the market: a rough CAPM
      # scaling, not a cost-of-capital build-up.
      wacc: rnd(DEFAULT_WACC + ((num_or(metrics[:beta], 1.0) - 1.0) * 0.02), 4),
      terminal_growth: DEFAULT_TERMINAL_GROWTH,
      net_debt: num_or(metrics[:net_debt], 0.0),
      shares_diluted: num_or(metrics[:shares_diluted], 1.0),
      start_year: num_or(latest[:fiscal_year], 2026).to_i + 1
    )
  end

  # ------------------------------------------------------------------ helpers

  # Python's round() rounds the *exact* binary value half-to-even. Ruby's
  # Float#round works on a scaled double and rounds half-up by default, so the
  # displayed figures would drift from the reference on ties (12.25 -> 12.3
  # instead of 12.2) and `half: :even` misreads near-ties such as
  # 0.23250000000000004 as ties. Rational arithmetic reproduces Python exactly;
  # every rounded output goes through here.
  def rnd(value, digits)
    float = value.to_f
    return float unless float.finite?

    scale = 10**digits
    Rational((float.to_r * scale).round(half: :even), scale).to_f
  end

  def round_stats(stats, digits = 2)
    stats.transform_values { |v| v.is_a?(Float) ? rnd(v, digits) : v }
  end

  # Python truthiness for a numeric: nil and zero are both "missing".
  def number?(value)
    !value.nil? && value != 0
  end

  # Python's `float(x or default)`: nil *and* zero fall through to the default.
  def num_or(value, default)
    number?(value) ? value.to_f : default.to_f
  end

  def to_assumptions(assumptions)
    assumptions.is_a?(DcfAssumptions) ? assumptions : DcfAssumptions.from_h(assumptions)
  end

  def multiples_for(row, enterprise_value:, price:)
    revenue = (row[:revenue] || 0.0).to_f
    ebitda = (row[:ebitda] || 0.0).to_f
    eps = (row[:eps] || 0.0).to_f
    {
      fiscal_year: row[:fiscal_year],
      is_estimate: row[:is_estimate] ? true : false,
      revenue: revenue,
      ebitda: ebitda,
      ebitda_margin: number?(revenue) ? rnd(ebitda / revenue, 4) : nil,
      eps: eps,
      ev_revenue: number?(revenue) ? rnd(enterprise_value / revenue, 2) : nil,
      ev_ebitda: number?(ebitda) ? rnd(enterprise_value / ebitda, 2) : nil,
      pe: number?(eps) ? rnd(price / eps, 2) : nil
    }
  end

  # One bar of the football field (Python's ValuationRange.as_dict).
  def valuation_range(method, low, high, basis: "", detail: {})
    low, high = [low.to_f, high.to_f].sort
    {
      method: method,
      low: rnd(low, 2),
      high: rnd(high, 2),
      mid: rnd((low + high) / 2, 2),
      basis: basis,
      detail: detail
    }
  end

  private_class_method :rnd, :round_stats, :number?, :num_or, :to_assumptions, :multiples_for, :valuation_range
end
