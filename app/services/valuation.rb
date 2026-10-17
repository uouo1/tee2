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
# Port of argos/valuation.py with the corrections an investment-analyst audit
# required (docs/AUDIT.md): multiples on the latest twelve months when a 10-Q
# allows it, an EV bridge that deducts non-controlling interest and preferred
# equity and refuses to bridge when net debt is unknown, a DCF whose
# working-capital charge follows the CHANGE in revenue, whose growth path
# interpolates to the terminal rate, whose exit-multiple terminal value is
# discounted from year N, with a stub period from the valuation date and a
# built-up WACC, and a football field whose conclusion excludes reference bars
# (the 52-week range) and a revenue multiple applied to a margin outlier.
# `Valuation::DcfAssumptions` lives in valuation/dcf_assumptions.rb.
module Valuation
  MULTIPLES = %i[ev_revenue ev_ebitda pe].freeze
  NTM_MULTIPLES = %i[ev_revenue_ntm ev_ebitda_ntm pe_ntm].freeze
  MULTIPLE_LABELS = {
    ev_revenue: "EV / Revenue", ev_ebitda: "EV / EBITDA", pe: "P / E",
    ev_revenue_ntm: "EV / NTM Revenue", ev_ebitda_ntm: "EV / NTM EBITDA", pe_ntm: "NTM P / E"
  }.freeze
  # A next-twelve-months comps bar needs this many peers with an NTM multiple.
  MIN_NTM_PEERS = 3

  # Valuation defaults (argos/config.py `Config`), overridable per pitch book.
  DEFAULT_WACC = 0.095 # only when no WACC build is possible (no market cap at all)
  DEFAULT_TERMINAL_GROWTH = 0.025
  DEFAULT_TAX_RATE = 0.23
  PROJECTION_YEARS = 5

  # Cost-of-capital build inputs. House defaults, printed with every DCF so a
  # reader sees them and a banker overrides them per deck; they are not market
  # observations as of the valuation date.
  RISK_FREE_RATE = 0.0425
  EQUITY_RISK_PREMIUM = 0.05
  DEBT_SPREAD = 0.0175 # pre-tax cost of debt = risk-free + spread when no issuer yield is loaded
  DEFAULT_BETA = 1.0

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
      mean: fsum(clean) / clean.size
    }
  end

  # ------------------------------------------------------------------ company

  # Capital structure and trading multiples for one company.
  #
  # `latest_actual` is the most recent reported fiscal year; `ltm` the trailing
  # twelve months when the loader could build one from a 10-Q; `valuation_basis`
  # is whichever of the two the comps and the football field use (LTM when it
  # exists), labelled in `basis_label` so no page shows a multiple without its
  # vintage. `forward` holds each estimate year.
  def company_metrics(ticker, forward_years: 2)
    company = Company.find_ticker(ticker)
    return nil unless company

    market = company.market_datum
    financials = company.financials.order(:fiscal_year, :period_type).map { |f| f.attributes.symbolize_keys }
    fiscal = financials.reject { |f| f[:period_type] == "LTM" }
    actuals = fiscal.reject { |f| f[:is_estimate] }
    latest = actuals.last || fiscal.last
    return nil if latest.nil?

    ltm = financials.select { |f| f[:period_type] == "LTM" }.max_by { |f| f[:period_end].to_s }

    price = (market&.share_price || 0.0).to_f
    shares = (market&.shares_diluted || 0.0).to_f
    # Unknown net debt is unknown, not zero: a verifier found a peer with no
    # balance-sheet data feeding the target's valuation range through an EV
    # computed as if it were debt-free. EV and EV multiples stay nil.
    net_debt = market&.net_debt.nil? ? nil : market.net_debt.to_f
    minority_interest = market&.minority_interest&.to_f
    preferred_equity = market&.preferred_equity&.to_f
    other_claims = minority_interest.to_f + preferred_equity.to_f
    market_cap = price * shares
    enterprise_value = net_debt.nil? ? nil : market_cap + net_debt + other_claims

    basis_row = ltm || latest
    forwards = fiscal.select { |f| f[:is_estimate] }.first(forward_years)
                     .map { |f| multiples_for(f, enterprise_value: enterprise_value, price: price) }
    basis_multiples = multiples_for(basis_row, enterprise_value: enterprise_value, price: price)
    ntm = ntm_metrics(fiscal, basis_multiples, as_of: market&.as_of, enterprise_value: enterprise_value, price: price)
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
      # The cover-page count travels with the diluted weighted-average so the
      # company page and comps table can say which basis the per-share figures
      # rest on (they are equal when the filer reported no diluted count and
      # the loader fell back). Nil when no market data was loaded.
      shares_basic: market&.shares_basic&.to_f,
      net_debt: net_debt,
      net_debt_as_of: market&.net_debt_as_of,
      balance_sheet_form: market&.balance_sheet_form,
      debt_note: market&.debt_note,
      minority_interest: minority_interest,
      preferred_equity: preferred_equity,
      other_claims: rnd(other_claims, 1),
      market_cap: rnd(market_cap, 1),
      enterprise_value: enterprise_value.nil? ? nil : rnd(enterprise_value, 1),
      ev_bridge: {
        price_date: market&.as_of,
        share_price: price,
        shares_diluted: shares,
        market_cap: rnd(market_cap, 1),
        net_debt: net_debt,
        balance_sheet_date: market&.net_debt_as_of,
        balance_sheet_form: market&.balance_sheet_form,
        minority_interest: minority_interest,
        preferred_equity: preferred_equity,
        enterprise_value: enterprise_value.nil? ? nil : rnd(enterprise_value, 1)
      },
      week52_low: market&.week52_low,
      week52_high: market&.week52_high,
      beta: market&.beta,
      latest_actual: multiples_for(latest, enterprise_value: enterprise_value, price: price),
      ltm: ltm && multiples_for(ltm, enterprise_value: enterprise_value, price: price),
      valuation_basis: basis_multiples,
      basis_label: basis_label(basis_row),
      ntm: ntm,
      forward: forwards,
      financials: financials
    }
  end

  # Next-twelve-months figures, calendarised the way a comps page does it: the
  # fiscal year in progress at `as_of` and the one after, weighted by the share
  # of the current year still ahead. Revenue and EPS come from the rows
  # (consensus estimates carry `estimate_source`); EBITDA too when a row has
  # it, otherwise it is derived from NTM revenue at the basis row's EBITDA
  # margin and flagged, because no public source publishes consensus EBITDA.
  # Nil when no fiscal year ends after `as_of` or when nothing beyond the
  # current year is estimated.
  def ntm_metrics(fiscal_rows, basis, as_of:, enterprise_value:, price:)
    return nil if fiscal_rows.empty?

    as_of = as_of.nil? ? Date.today : (as_of.is_a?(Date) ? as_of : Date.iso8601(as_of.to_s))
    rows = fiscal_rows.sort_by { |row| row[:fiscal_year].to_i }
    current = rows.find { |row| fiscal_period_end(row) > as_of }
    return nil if current.nil?

    following = rows.find { |row| row[:fiscal_year].to_i == current[:fiscal_year].to_i + 1 }
    return nil if following.nil? && !current[:is_estimate]

    weight = ((fiscal_period_end(current) - as_of).to_f / 365.25).clamp(0.0, 1.0)
    blend = lambda do |key|
      first = current[key]
      second = following && following[key]
      next nil if first.nil?
      next first.to_f if second.nil?

      weight * first.to_f + (1 - weight) * second.to_f
    end
    revenue = blend.call(:revenue)
    eps = blend.call(:eps)
    ebitda = blend.call(:ebitda)
    derived = false
    if ebitda.nil? && revenue && basis && basis[:ebitda_margin]
      ebitda = revenue * basis[:ebitda_margin].to_f
      derived = true
    end
    {
      revenue: revenue && rnd(revenue, 1),
      ebitda: ebitda && rnd(ebitda, 1),
      ebitda_derived: derived,
      eps: eps && rnd(eps, 2),
      ev_revenue: number?(revenue) && !enterprise_value.nil? ? rnd(enterprise_value / revenue, 2) : nil,
      ev_ebitda: number?(ebitda) && !enterprise_value.nil? ? rnd(enterprise_value / ebitda, 2) : nil,
      pe: number?(eps) && number?(price) ? rnd(price / eps, 2) : nil,
      weight_current_year: rnd(weight, 4),
      fiscal_years: [current[:fiscal_year], following && following[:fiscal_year]].compact,
      period_end: fiscal_period_end(current) >> 12 > as_of ? (as_of >> 12) : fiscal_period_end(current),
      source: (following && following[:estimate_source]) || current[:estimate_source] || "estimate rows",
      label: "NTM"
    }
  end

  # A fiscal year ends on its period_end, or on 31 December of its year when the
  # row carries no date (seeded data).
  def fiscal_period_end(row)
    period_end = row[:period_end]
    return Date.new(row[:fiscal_year].to_i, 12, 31) if period_end.nil?

    period_end.is_a?(Date) ? period_end : Date.iso8601(period_end.to_s)
  end

  # "LTM Jun-26" or "FY2025": the vintage every multiple is quoted on.
  def basis_label(row)
    return "n/a" if row.nil?
    return "FY#{row[:fiscal_year]}" unless row[:period_type] == "LTM"

    period_end = row[:period_end]
    period_end = Date.iso8601(period_end.to_s) unless period_end.is_a?(Date) || period_end.nil?
    period_end ? "LTM #{period_end.strftime('%b-%y')}" : "LTM"
  end

  # -------------------------------------------------------------- trading comps

  # Comparable companies table plus the distribution of each multiple. Each row
  # says which period its multiples are on (`basis`); the statistics pool LTM
  # and fiscal-year multiples when the set is mixed, and `bases` reports the mix.
  def comps_table(tickers, exclude: nil)
    rows = []
    Array(tickers).each do |ticker|
      next if exclude && ticker.to_s.upcase == exclude.to_s.upcase

      metrics = company_metrics(ticker)
      next unless metrics

      basis = metrics[:valuation_basis]
      rows << {
        ticker: metrics[:ticker],
        name: metrics[:name],
        country: metrics[:country],
        share_price: metrics[:share_price],
        price_date: metrics[:as_of],
        market_cap: metrics[:market_cap],
        enterprise_value: metrics[:enterprise_value],
        net_debt: metrics[:net_debt],
        net_debt_as_of: metrics[:net_debt_as_of],
        other_claims: metrics[:other_claims],
        shares_diluted: metrics[:shares_diluted],
        shares_basic: metrics[:shares_basic],
        revenue: rnd(basis[:revenue], 1),
        ebitda: rnd(basis[:ebitda], 1),
        ebitda_margin: basis[:ebitda_margin],
        ev_revenue: basis[:ev_revenue],
        ev_ebitda: basis[:ev_ebitda],
        pe: basis[:pe],
        fiscal_year: basis[:fiscal_year],
        basis: metrics[:basis_label],
        period_type: basis[:period_type],
        ev_revenue_ntm: metrics.dig(:ntm, :ev_revenue),
        ev_ebitda_ntm: metrics.dig(:ntm, :ev_ebitda),
        pe_ntm: metrics.dig(:ntm, :pe),
        ntm_ebitda_derived: metrics.dig(:ntm, :ebitda_derived)
      }
    end
    # Largest first. Python's sort is stable; Ruby's sort_by is not, so the
    # original index breaks ties the same way.
    rows = rows.each_with_index.sort_by { |row, index| [-(row[:enterprise_value] || 0), index] }.map(&:first)
    stats = (MULTIPLES + NTM_MULTIPLES).to_h { |m| [m, round_stats(describe(rows.map { |r| r[m] }))] }
    { rows: rows, stats: stats, labels: MULTIPLE_LABELS, bases: rows.map { |r| r[:basis] }.tally }
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
  # `kind` is "ev" (bridge through net debt and other claims) or "equity"
  # (already a per-share earnings multiple).
  def implied_from_multiple(multiple_low, multiple_high, metric_value:, kind:, net_debt:, shares:, other_claims: 0.0)
    return nil if !number?(shares) || multiple_low.nil? || multiple_high.nil? || !number?(metric_value)
    return nil if kind.to_s == "ev" && net_debt.nil? # cannot bridge EV to equity without it

    low_m, high_m = [multiple_low.to_f, multiple_high.to_f].sort
    metric_value = metric_value.to_f
    per_share = lambda do |multiple|
      if kind.to_s == "ev"
        (multiple * metric_value - net_debt.to_f - other_claims.to_f) / shares.to_f
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

  # -------------------------------------------------------------------- WACC

  # Cost of capital built from its parts rather than a constant: CAPM cost of
  # equity, risk-free plus a spread for debt, the market capital structure for
  # the weights. Every input is echoed so the DCF slide can show the build.
  # Net debt stands in for gross debt in the weights (gross debt is not stored).
  def wacc_build(metrics, risk_free_rate: RISK_FREE_RATE, equity_risk_premium: EQUITY_RISK_PREMIUM,
                 debt_spread: DEBT_SPREAD, beta: nil, tax_rate: nil)
    beta_value = beta || metrics[:beta]
    beta_assumed = !number?(beta_value)
    beta_value = DEFAULT_BETA if beta_assumed
    cost_of_equity = risk_free_rate + beta_value.to_f * equity_risk_premium
    pre_tax_cost_of_debt = risk_free_rate + debt_spread
    tax = tax_rate || normalised_tax_rate(metrics)
    after_tax_cost_of_debt = pre_tax_cost_of_debt * (1 - tax)
    equity = [metrics[:market_cap].to_f, 0.0].max
    debt = [metrics[:net_debt].to_f, 0.0].max
    # Without a market capitalisation there is no capital structure to weight,
    # so the cost of capital is the cost of equity (all-equity), not all-debt.
    weight_debt = equity.positive? ? debt / (equity + debt) : 0.0
    wacc = (1 - weight_debt) * cost_of_equity + weight_debt * after_tax_cost_of_debt

    notes = []
    notes << "Beta not loaded: market beta of #{DEFAULT_BETA} assumed, so the cost of equity is the market's." if beta_assumed
    notes << "Debt weight uses net debt as a proxy for gross debt." if weight_debt.positive?
    notes << "No market capitalisation: all-equity cost of capital." unless equity.positive?
    notes << "Risk-free rate, equity risk premium and debt spread are house defaults, not observations as of the valuation date."
    {
      risk_free_rate: risk_free_rate,
      equity_risk_premium: equity_risk_premium,
      beta: rnd(beta_value, 2),
      beta_assumed: beta_assumed,
      cost_of_equity: rnd(cost_of_equity, 4),
      pre_tax_cost_of_debt: rnd(pre_tax_cost_of_debt, 4),
      tax_rate: rnd(tax, 4),
      after_tax_cost_of_debt: rnd(after_tax_cost_of_debt, 4),
      weight_debt: rnd(weight_debt, 4),
      weight_equity: rnd(1 - weight_debt, 4),
      wacc: rnd(wacc, 4),
      notes: notes
    }
  end

  # The tax rate a DCF should carry: the latest filed effective rate, held to a
  # normalised band because one year's rate is not a forecast.
  def normalised_tax_rate(metrics)
    actuals = (metrics[:financials] || []).reject { |f| f[:is_estimate] || f[:period_type] == "LTM" }
    filed = actuals.last&.dig(:tax_rate)
    filed.nil? ? DEFAULT_TAX_RATE : filed.to_f.clamp(0.15, 0.35)
  end

  # -------------------------------------------------------------------- DCF

  # Project unlevered free cash flow, discount it, and bridge to per share.
  #
  # Takes a DcfAssumptions (or a partial hash, coerced the same way the API
  # payload is). Invalid inputs raise ArgumentError.
  #
  # Mechanics (each one was an audit finding against the reference):
  # * growth interpolates linearly from `revenue_growth` to `terminal_growth`
  #   over the explicit years, whatever the sign of the first rate;
  # * the working-capital charge is `nwc_pct_revenue` × the CHANGE in revenue,
  #   so flat revenue ties up nothing and a decline releases cash;
  # * year 1 counts only its remaining `stub_fraction` and every cash flow is
  #   discounted from the valuation date (mid-period when the convention is on);
  # * the terminal year is built explicitly: margin held, capex floored at D&A
  #   when `terminal_capex_floor`, working capital on terminal growth;
  # * a Gordon terminal value sits at N − ½ under the mid-year convention, an
  #   exit-multiple value (a point-in-time price at year end) always at N;
  # * unknown net debt (nil) gives an enterprise value and no equity bridge.
  def run_dcf(assumptions)
    a = to_assumptions(assumptions)
    raise ArgumentError, "wacc must be positive" if a.wacc <= 0
    raise ArgumentError, "base_revenue must be positive" if a.base_revenue <= 0
    raise ArgumentError, "years must be positive" if a.years < 1
    raise ArgumentError, "stub_fraction must be within (0, 1]" unless a.stub_fraction.to_f.positive? && a.stub_fraction.to_f <= 1.0
    if a.exit_multiple.nil? && a.terminal_growth >= a.wacc
      raise ArgumentError, "terminal growth must be below WACC when using a growth-based terminal value"
    end

    wacc = a.wacc.to_f
    stub = a.stub_fraction.to_f
    projections = []
    prior_revenue = a.base_revenue.to_f
    margin = a.ebitda_margin.to_f
    pv_total = 0.0

    growth_path(a).each_with_index do |growth, offset|
      index = offset + 1
      revenue = prior_revenue * (1 + growth)
      margin += a.margin_expansion
      ebitda = revenue * margin
      dep_amort = revenue * a.da_pct_revenue
      ebit = ebitda - dep_amort
      taxes = [0.0, ebit].max * a.tax_rate
      capex = revenue * a.capex_pct_revenue
      nwc_change = a.nwc_pct_revenue * (revenue - prior_revenue)
      fcf_full_year = ebit - taxes + dep_amort - capex - nwc_change
      fraction = index == 1 ? stub : 1.0
      fcf = fcf_full_year * fraction
      period = discount_period(index, stub, a.mid_year_convention)
      discount = 1.0 / ((1 + wacc)**period)
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
        nwc_change: rnd(nwc_change, 1),
        fcf_full_year: rnd(fcf_full_year, 1),
        period_fraction: rnd(fraction, 4),
        fcf: rnd(fcf, 1),
        discount_period: rnd(period, 4),
        discount_factor: rnd(discount, 4),
        pv_fcf: rnd(pv, 1)
      }
      prior_revenue = revenue
    end

    # Terminal year (N+1), built explicitly so the bridge can be ticked and tied.
    final_revenue = prior_revenue
    terminal_growth = a.terminal_growth.to_f
    t_revenue = final_revenue * (1 + terminal_growth)
    t_ebitda = t_revenue * margin
    t_dep_amort = t_revenue * a.da_pct_revenue
    t_ebit = t_ebitda - t_dep_amort
    t_taxes = [0.0, t_ebit].max * a.tax_rate
    t_capex = t_revenue * a.capex_pct_revenue
    capex_floored = a.terminal_capex_floor && t_capex < t_dep_amort
    t_capex = t_dep_amort if capex_floored
    t_nwc_change = a.nwc_pct_revenue * (t_revenue - final_revenue)
    terminal_fcf = t_ebit - t_taxes + t_dep_amort - t_capex - t_nwc_change
    final_ebitda = final_revenue * margin
    years_end = stub + a.years - 1 # the end of the last explicit year, measured from the valuation date

    if a.exit_multiple.nil?
      terminal_value = terminal_fcf / (wacc - terminal_growth)
      terminal_method = format("Gordon growth at %.1f%%", terminal_growth * 100)
      terminal_period = a.mid_year_convention ? years_end - 0.5 : years_end
    else
      terminal_value = a.exit_multiple * final_ebitda
      terminal_method = format("%.1fx exit EBITDA multiple", a.exit_multiple)
      terminal_period = years_end # a multiple is a price at year end, whatever the flow convention
    end
    pv_terminal = terminal_value / ((1 + wacc)**terminal_period)

    enterprise_value = pv_total + pv_terminal
    net_debt = a.net_debt.nil? ? nil : a.net_debt.to_f
    equity_value = net_debt.nil? ? nil : enterprise_value - net_debt - a.other_claims.to_f
    per_share = !equity_value.nil? && number?(a.shares_diluted) ? equity_value / a.shares_diluted.to_f : nil
    first_ebitda = projections.first[:ebitda]

    {
      assumptions: a.to_h,
      valuation_date: a.valuation_date,
      stub_fraction: rnd(stub, 4),
      projections: projections,
      terminal_year: {
        year: a.start_year + a.years,
        revenue: rnd(t_revenue, 1), growth: rnd(terminal_growth, 4), ebitda: rnd(t_ebitda, 1),
        ebitda_margin: rnd(margin, 4), ebit: rnd(t_ebit, 1), taxes: rnd(t_taxes, 1),
        dep_amort: rnd(t_dep_amort, 1), capex: rnd(t_capex, 1), capex_floored_at_da: capex_floored,
        nwc_change: rnd(t_nwc_change, 1), fcf: rnd(terminal_fcf, 1)
      },
      pv_explicit: rnd(pv_total, 1),
      terminal_value: rnd(terminal_value, 1),
      pv_terminal: rnd(pv_terminal, 1),
      terminal_method: terminal_method,
      terminal_discount_period: rnd(terminal_period, 4),
      terminal_share_of_ev: number?(enterprise_value) ? rnd(pv_terminal / enterprise_value, 4) : nil,
      # Cross-checks a banker asks for: what multiple the Gordon value implies,
      # what growth the exit multiple implies.
      implied_exit_multiple: number?(final_ebitda) ? rnd(terminal_value / final_ebitda, 2) : nil,
      implied_terminal_growth: number?(terminal_value) ? rnd(wacc - terminal_fcf / terminal_value, 4) : nil,
      enterprise_value: rnd(enterprise_value, 1),
      net_debt: net_debt.nil? ? nil : rnd(net_debt, 1),
      other_claims: rnd(a.other_claims.to_f, 1),
      equity_value: equity_value.nil? ? nil : rnd(equity_value, 1),
      value_per_share: per_share.nil? ? nil : rnd(per_share, 2),
      bridge_note: net_debt.nil? ? "Net debt unknown: enterprise value only, no equity bridge or per-share value." : nil,
      implied_ev_ebitda: number?(first_ebitda) ? rnd(enterprise_value / first_ebitda, 2) : nil
    }
  end

  # Year-by-year growth: linear from the first-year rate to the terminal rate.
  def growth_path(a)
    first = a.revenue_growth.to_f
    last = a.terminal_growth.to_f
    return [first] if a.years == 1

    (0...a.years).map { |i| first + (last - first) * i / (a.years - 1.0) }
  end

  # Years from the valuation date to the point a year's cash flow is discounted
  # from: the end of the (stub) year, or its middle under the mid-year convention.
  def discount_period(index, stub, mid_year)
    fraction = index == 1 ? stub : 1.0
    elapsed = stub + (index - 1)
    mid_year ? elapsed - fraction / 2.0 : elapsed
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
  # A range carries `in_conclusion`: the 52-week trading range is a reference
  # bar, never a valuation method, and a revenue multiple is not applied to a
  # target whose margin sits outside the peers' interquartile range. The
  # concluded range is the median low to the median high of the bars that
  # remain, and nil when none does.
  def football_field(target_ticker, comp_tickers, assumptions: nil)
    target = company_metrics(target_ticker)
    raise ArgumentError, "unknown ticker: #{target_ticker}" unless target

    basis = target[:valuation_basis]
    label = target[:basis_label]
    net_debt = target[:net_debt]
    other_claims = target[:other_claims].to_f
    shares = target[:shares_diluted]
    comps = comps_table(comp_tickers, exclude: target_ticker)
    precedents = precedent_transactions(sector: target[:sector])
    ranges = []

    # Bankers lead with the forward multiple when the set supports one.
    ntm = target[:ntm]
    ntm_ebitda = comps[:stats][:ev_ebitda_ntm]
    if ntm && number?(ntm[:ebitda]) && ntm_ebitda[:count].to_i >= MIN_NTM_PEERS
      implied = implied_from_multiple(
        ntm_ebitda[:p25], ntm_ebitda[:p75],
        metric_value: ntm[:ebitda], kind: "ev", net_debt: net_debt, shares: shares, other_claims: other_claims
      )
      if implied
        ranges << valuation_range(
          "Trading comps — NTM EV/EBITDA", implied[:low], implied[:high],
          basis: "#{implied[:multiple_low]}x–#{implied[:multiple_high]}x on NTM EBITDA of #{format('%.0f', implied[:metric_value])} "                  "(#{ntm[:ebitda_derived] ? 'consensus revenue at the current margin' : 'estimate rows'}; #{ntm_ebitda[:count]} peers)",
          detail: implied.merge(ebitda_derived: ntm[:ebitda_derived], source: ntm[:source])
        )
      end
    end

    comp_ebitda = comps[:stats][:ev_ebitda]
    implied = implied_from_multiple(
      comp_ebitda[:p25], comp_ebitda[:p75],
      metric_value: basis[:ebitda], kind: "ev", net_debt: net_debt, shares: shares, other_claims: other_claims
    )
    if implied
      ranges << valuation_range(
        "Trading comps — EV/EBITDA", implied[:low], implied[:high],
        basis: "#{implied[:multiple_low]}x–#{implied[:multiple_high]}x on #{label} " \
               "EBITDA of #{format('%.0f', implied[:metric_value])}",
        detail: implied
      )
    end

    comp_revenue = comps[:stats][:ev_revenue]
    implied = implied_from_multiple(
      comp_revenue[:p25], comp_revenue[:p75],
      metric_value: basis[:revenue], kind: "ev", net_debt: net_debt, shares: shares, other_claims: other_claims
    )
    if implied
      outlier = margin_outlier(basis[:ebitda_margin], comps[:rows])
      ranges << valuation_range(
        "Trading comps — EV/Revenue", implied[:low], implied[:high],
        basis: "#{implied[:multiple_low]}x–#{implied[:multiple_high]}x on #{label} " \
               "revenue of #{format('%.0f', implied[:metric_value])}",
        detail: implied,
        in_conclusion: outlier.nil?,
        note: outlier
      )
    end

    # With no precedent deals the quartiles are nil and no bar is drawn: a
    # precedent range can only come from real transactions, never a placeholder.
    precedent_ebitda = precedents[:stats][:ev_ebitda]
    implied = implied_from_multiple(
      precedent_ebitda[:p25], precedent_ebitda[:p75],
      metric_value: basis[:ebitda], kind: "ev", net_debt: net_debt, shares: shares, other_claims: other_claims
    )
    if implied
      ranges << valuation_range(
        "Precedent transactions — EV/EBITDA", implied[:low], implied[:high],
        basis: "#{implied[:multiple_low]}x–#{implied[:multiple_high]}x on #{label} " \
               "EBITDA (#{precedent_ebitda[:count]} deals)",
        detail: implied
      )
    end

    wacc = wacc_build(target)
    dcf_assumptions = default_assumptions(target, wacc: wacc)
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
    if band[:min].nil?
      dcf_note = base[:bridge_note] || "DCF per-share value unavailable (no share count)."
    else
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
        basis: "Last twelve months of trading (reference only, not a valuation method)",
        in_conclusion: false, reference: true
      )
    end

    concluded = ranges.select { |r| r[:in_conclusion] }
    lows = ranges.map { |r| r[:low] }
    highs = ranges.map { |r| r[:high] }
    {
      target: {
        ticker: target[:ticker], name: target[:name], share_price: target[:share_price],
        shares_diluted: shares, net_debt: net_debt, other_claims: rnd(other_claims, 1), currency: target[:currency],
        market_cap: target[:market_cap], enterprise_value: target[:enterprise_value],
        basis_label: label, price_date: target[:as_of], balance_sheet_date: target[:net_debt_as_of]
      },
      ranges: ranges,
      axis: {
        min: lows.empty? ? 0 : rnd(lows.min * 0.9, 2),
        max: highs.empty? ? 0 : rnd(highs.max * 1.05, 2)
      },
      reference_price: target[:share_price],
      comps: comps,
      precedents: precedents,
      wacc: wacc,
      dcf: base,
      dcf_note: dcf_note,
      sensitivity: sensitivity,
      # Median low to median high of the bars that are valuation methods: the
      # interquartile version let whichever methodology had the widest band
      # dictate the conclusion, and averaging in the 52-week range let last
      # year's trading set this year's value.
      concluded_range: {
        low: concluded.empty? ? nil : rnd(percentile(concluded.map { |r| r[:low] }, 0.5), 2),
        high: concluded.empty? ? nil : rnd(percentile(concluded.map { |r| r[:high] }, 0.5), 2),
        methods: concluded.map { |r| r[:method] }
      }
    }
  end

  # A note when the target's EBITDA margin falls outside the peers' interquartile
  # range (a revenue multiple then prices the wrong business); nil otherwise.
  def margin_outlier(target_margin, comp_rows)
    margins = comp_rows.map { |r| r[:ebitda_margin] }.compact
    return nil if target_margin.nil? || margins.size < 3

    p25 = percentile(margins, 0.25)
    p75 = percentile(margins, 0.75)
    return nil if target_margin.to_f.between?(p25, p75)

    format("Target EBITDA margin %.1f%% is outside the peer interquartile range %.1f%%–%.1f%%: " \
           "the revenue multiple is shown but not used in the conclusion.",
           target_margin.to_f * 100, p25 * 100, p75 * 100)
  end

  # Seed DCF assumptions from a company's own history.
  #
  # Growth comes from the last two reported fiscal years, margin, D&A and capex
  # intensity from the freshest period (LTM when there is one), working-capital
  # intensity from a three-year average (a single year's swing is noise), the
  # tax rate is held to a normalised band because one year's effective rate is
  # not a forecast, and the WACC is built up (see wacc_build). The projection
  # starts with the fiscal year under way at the valuation date, of which only
  # the remaining `stub_fraction` is counted. Net debt and the share count stay
  # nil when unknown: the DCF then reports an enterprise value and no per-share
  # figure rather than bridging through zero.
  def default_assumptions(metrics, wacc: nil)
    financials = metrics[:financials] || []
    fiscal = financials.reject { |f| f[:period_type] == "LTM" }
    actuals = fiscal.reject { |f| f[:is_estimate] }
    latest = actuals.last || fiscal.last || {}
    ltm = financials.select { |f| f[:period_type] == "LTM" }.max_by { |f| f[:period_end].to_s }
    fresh = ltm || latest
    revenue = (latest[:revenue] || 0.0).to_f
    fresh_revenue = (fresh[:revenue] || 0.0).to_f
    ebitda = (fresh[:ebitda] || 0.0).to_f

    growth = 0.10
    prior_revenue = actuals.size >= 2 ? actuals[-2][:revenue] : nil
    growth = (revenue / prior_revenue.to_f - 1).clamp(-0.1, 0.45) if number?(prior_revenue)

    nwc_ratios = actuals.last(3).filter_map do |f|
      f[:nwc_change].to_f / f[:revenue].to_f if !f[:nwc_change].nil? && number?(f[:revenue])
    end
    nwc_pct = nwc_ratios.empty? ? 0.012 : fsum(nwc_ratios) / nwc_ratios.size
    nwc_pct = nwc_pct.clamp(-0.03, 0.05)

    start_year = num_or(latest[:fiscal_year], 2026).to_i + 1
    valuation_date = metrics[:as_of] || Date.today
    valuation_date = Date.iso8601(valuation_date.to_s) unless valuation_date.is_a?(Date)
    period_end = latest[:period_end]
    period_end = Date.iso8601(period_end.to_s) unless period_end.nil? || period_end.is_a?(Date)
    first_year_end = period_end ? period_end >> 12 : Date.new(start_year, 12, 31)
    stub = ((first_year_end - valuation_date).to_f / 365.25).clamp(0.02, 1.0)

    build = wacc || wacc_build(metrics)
    DcfAssumptions.new(
      base_revenue: revenue,
      revenue_growth: rnd(growth, 4),
      ebitda_margin: number?(fresh_revenue) ? rnd(ebitda / fresh_revenue, 4) : 0.2,
      da_pct_revenue: number?(fresh_revenue) ? rnd((fresh[:dep_amort] || 0).to_f / fresh_revenue, 4) : 0.05,
      capex_pct_revenue: number?(fresh_revenue) ? rnd((fresh[:capex] || 0).to_f / fresh_revenue, 4) : 0.04,
      nwc_pct_revenue: rnd(nwc_pct, 4),
      tax_rate: build[:tax_rate],
      wacc: build[:wacc],
      terminal_growth: DEFAULT_TERMINAL_GROWTH,
      net_debt: metrics[:net_debt].nil? ? nil : metrics[:net_debt].to_f,
      other_claims: metrics[:other_claims].to_f,
      shares_diluted: number?(metrics[:shares_diluted]) ? metrics[:shares_diluted].to_f : nil,
      stub_fraction: rnd(stub, 4),
      start_year: start_year,
      valuation_date: valuation_date
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

  # CPython's `sum()` of floats has been Neumaier-compensated since 3.12, so
  # the reference mean of [0.1] * 10 is exactly 0.1 where a naive left-to-right
  # sum gives 0.09999999999999999. Reproduce it wherever the Python calls
  # `sum()` so statistics agree with the reference to the last digit (it is
  # also simply the more accurate figure).
  def fsum(values)
    total = 0.0
    compensation = 0.0
    values.each do |value|
      x = value.to_f
      t = total + x
      compensation += total.abs >= x.abs ? (total - t) + x : (x - t) + total
      total = t
    end
    # Like CPython: skip the correction when it is zero or would turn an
    # infinite sum into NaN.
    compensation != 0.0 && compensation.finite? ? total + compensation : total
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
      period_type: row[:period_type] || "FY",
      period_end: row[:period_end],
      basis: basis_label(row),
      is_estimate: row[:is_estimate] ? true : false,
      revenue: revenue,
      ebitda: ebitda,
      ebitda_margin: number?(revenue) ? rnd(ebitda / revenue, 4) : nil,
      eps: eps,
      ev_revenue: number?(revenue) && !enterprise_value.nil? ? rnd(enterprise_value / revenue, 2) : nil,
      ev_ebitda: number?(ebitda) && !enterprise_value.nil? ? rnd(enterprise_value / ebitda, 2) : nil,
      pe: number?(eps) ? rnd(price / eps, 2) : nil
    }
  end

  # One bar of the football field (Python's ValuationRange.as_dict), plus
  # whether it counts towards the concluded range and why not.
  def valuation_range(method, low, high, basis: "", detail: {}, in_conclusion: true, reference: false, note: nil)
    low, high = [low.to_f, high.to_f].sort
    {
      method: method,
      low: rnd(low, 2),
      high: rnd(high, 2),
      mid: rnd((low + high) / 2, 2),
      basis: basis,
      detail: detail,
      in_conclusion: in_conclusion,
      reference: reference,
      note: note
    }
  end

  private_class_method :rnd, :round_stats, :fsum, :number?, :num_or, :to_assumptions, :multiples_for,
                       :valuation_range, :margin_outlier, :fiscal_period_end
end
