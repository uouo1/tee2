# frozen_string_literal: true

require "csv"

module Sources
  # Load real company data from SEC EDGAR.
  #
  # Three public endpoints do all the work:
  #
  # * company_tickers.json maps a ticker to a CIK;
  # * submissions/CIK….json lists every filing a company has made;
  # * api/xbrl/companyfacts/CIK….json carries the tagged financial facts.
  #
  # Fundamentals come from XBRL rather than from parsed text, so the figures that
  # reach a pitch book are the ones the company filed. Filing narrative is fetched
  # separately and ingested as the research corpus, which is what makes a deck
  # built this way auditable: every number has a tag and every quote has an
  # accession number.
  #
  # EBITDA is operating income plus depreciation and amortisation — the standard
  # proxy, and not always what a company calls "adjusted EBITDA" in its own release.
  #
  # All JSON structures here are the symbol-keyed hashes `Http.fetch_json`
  # returns (`facts[:facts][:"us-gaap"][:Revenues][:units][:USD]`).
  module Sec
    TICKER_INDEX_URL = "https://www.sec.gov/files/company_tickers.json"
    SUBMISSIONS_URL = "https://data.sec.gov/submissions/CIK%<cik>s.json"
    FACTS_URL = "https://data.sec.gov/api/xbrl/companyfacts/CIK%<cik>s.json"
    ARCHIVE_BASE = "https://www.sec.gov/Archives/edgar/data/%<cik>d/%<accession>s"

    # Preference order per concept: filers tag the same line differently.
    TAGS = {
      revenue: %w[
        RevenueFromContractWithCustomerExcludingAssessedTax
        RevenueFromContractWithCustomerIncludingAssessedTax
        Revenues
        SalesRevenueNet
        SalesRevenueGoodsNet
      ],
      operating_income: %w[OperatingIncomeLoss],
      dep_amort: %w[
        DepreciationDepletionAndAmortization
        DepreciationAmortizationAndAccretionNet
        DepreciationAndAmortization
        DepreciationDepletionAndAmortizationNonproduction
      ],
      net_income: %w[NetIncomeLoss ProfitLoss],
      eps: %w[EarningsPerShareDiluted EarningsPerShareBasicAndDiluted],
      capex: %w[
        PaymentsToAcquirePropertyPlantAndEquipment
        PaymentsToAcquireProductiveAssets
      ],
      pretax_income: %w[
        IncomeLossFromContinuingOperationsBeforeIncomeTaxesExtraordinaryItemsNoncontrollingInterest
        IncomeLossFromContinuingOperationsBeforeIncomeTaxesMinorityInterestAndIncomeLossFromEquityMethodInvestments
      ],
      income_tax: %w[IncomeTaxExpenseBenefit],
      diluted_shares: %w[WeightedAverageNumberOfDilutedSharesOutstanding]
    }.freeze
    INSTANT_TAGS = {
      cash: %w[
        CashAndCashEquivalentsAtCarryingValue
        CashCashEquivalentsRestrictedCashAndRestrictedCashEquivalents
        Cash
      ],
      short_term_investments: %w[
        ShortTermInvestments MarketableSecuritiesCurrent
        AvailableForSaleSecuritiesDebtSecuritiesCurrent
      ],
      debt_current: %w[
        LongTermDebtCurrent DebtCurrent
        LongTermDebtAndCapitalLeaseObligationsCurrent
      ],
      debt_noncurrent: %w[
        LongTermDebtNoncurrent LongTermDebtAndCapitalLeaseObligations
      ],
      # Borrowings as one line, for filers that tag neither split line.
      debt_total: %w[
        LongTermDebt DebtLongtermAndShorttermCombinedAmount DebtAndCapitalLeaseObligations DebtInstrumentCarryingAmount
      ],
      minority_interest: %w[MinorityInterest],
      preferred_equity: %w[PreferredStockValue PreferredStockCarryingAmount],
      assets_current: %w[AssetsCurrent],
      liabilities_current: %w[LiabilitiesCurrent]
    }.freeze

    FORM_DOC_TYPES = { "10-K" => "filing", "10-Q" => "filing", "8-K" => "press-release" }.freeze
    FORM_LABELS = { "10-K" => "Annual Report (10-K)", "10-Q" => "Quarterly Report (10-Q)" }.freeze
    ANNUAL_FORMS = %w[10-K 10-K/A].freeze
    MAX_FILING_CHARS = 320_000
    MIN_DOCUMENT_CHARS = 500
    FILING_COLUMNS = %i[form accessionNumber filingDate reportDate primaryDocument primaryDocDescription].freeze

    module_function

    # ------------------------------------------------------------------ lookup

    # Ticker to zero-padded CIK via the SEC's own index.
    def resolve_cik(ticker)
      index = Http.fetch_json(TICKER_INDEX_URL)
      wanted = ticker.upcase
      index.each_value do |row|
        return row[:cik_str].to_s.rjust(10, "0") if row[:ticker].to_s.upcase == wanted
      end
      nil
    end

    def fetch_submissions(cik)
      Http.fetch_json(format(SUBMISSIONS_URL, cik: cik), cache: false)
    end

    def fetch_facts(cik)
      Http.fetch_json(format(FACTS_URL, cik: cik), cache: false)
    end

    # ------------------------------------------------------------------- facts

    # Fiscal year for a period end date.
    #
    # 52/53-week filers end their year in the first days of January; Trimble's
    # "fiscal 2025" ends 2 January 2026. Labelling by calendar year of the end
    # date would call that FY2026, so early-January ends belong to the prior year.
    def fiscal_year(end_date)
      ended = Date.iso8601(end_date.to_s)
      ended.month == 1 && ended.day <= 15 ? ended.year - 1 : ended.year
    end

    QUARTERLY_FORMS = %w[10-Q 10-Q/A].freeze
    BALANCE_FORMS = (ANNUAL_FORMS + QUARTERLY_FORMS).freeze
    # Days in a year-to-date span on a Q1, Q2 or Q3 10-Q.
    YTD_SPANS = { 1 => (80..100), 2 => (170..190), 3 => (260..280) }.freeze

    # Annual observations by fiscal year for a duration concept, as
    # {year => {value:, period_end:, filed:, tag:}}.
    #
    # Tags are resolved PER YEAR in preference order: an earlier tag's value for
    # a year wins, a later tag fills the years the earlier ones lack. Resolving
    # once per company ("first tag with any data") lost every year after a tag
    # switch and, for Xylem, dropped the whole current-debt line (an audit
    # finding). Within a tag the most recently filed value wins: restatements.
    # A preferred tag carrying less than this share of another tag's value for
    # the same year is a sub-line, not the total (Charter tags one revenue
    # stream under RevenueFromContractWithCustomerIncludingAssessedTax, 889m,
    # while Revenues holds the 55bn total). Only the revenue concept uses it.
    SUB_LINE_RATIO = 0.2

    def duration_entries(facts, names, unit: "USD", sub_line_guard: false)
      us_gaap = facts.dig(:facts, :"us-gaap") || {}
      by_tag = names.map do |name|
        per_tag = {}
        (us_gaap.dig(name.to_sym, :units, unit.to_sym) || []).each do |entry|
          next unless ANNUAL_FORMS.include?(entry[:form]) && entry[:fp] == "FY"

          start, finish = entry[:start], entry[:end]
          next if start.blank? || finish.blank?

          span = (Date.iso8601(finish) - Date.iso8601(start)).to_i
          next unless (330..400).cover?(span) # a full year, not a quarter or a stub

          year = fiscal_year(finish)
          filed = entry[:filed].to_s
          if !per_tag.key?(year) || filed > per_tag[year][:filed]
            per_tag[year] = { value: entry[:val].to_f, period_end: Date.iso8601(finish), filed: filed, tag: name }
          end
        end
        per_tag
      end
      out = {}
      by_tag.each { |per_tag| per_tag.each { |year, row| out[year] ||= row } }
      return out unless sub_line_guard

      out.each do |year, row|
        candidates = by_tag.filter_map { |per_tag| per_tag[year] }
        largest = candidates.max_by { |c| c[:value].abs }
        out[year] = largest if largest && row[:value].abs < largest[:value].abs * SUB_LINE_RATIO
      end
      out
    end

    # Annual values by fiscal year for a duration concept (P&L, cash flow).
    def duration_values(facts, names, unit: "USD")
      duration_entries(facts, names, unit: unit).transform_values { |row| row[:value] }
    end

    # Balance-sheet observations by date for an instant concept, from the given
    # forms, as {Date => {value:, filed:, form:, tag:}}, with the same per-date
    # tag preference and latest-filed rule.
    def instant_entries(facts, names, forms: ANNUAL_FORMS, fiscal_year_only: true)
      us_gaap = facts.dig(:facts, :"us-gaap") || {}
      out = {}
      names.each do |name|
        per_tag = {}
        (us_gaap.dig(name.to_sym, :units, :USD) || []).each do |entry|
          next unless forms.include?(entry[:form])
          next if fiscal_year_only && entry[:fp] != "FY"

          finish = entry[:end]
          next if finish.blank?

          date = Date.iso8601(finish)
          filed = entry[:filed].to_s
          if !per_tag.key?(date) || filed > per_tag[date][:filed]
            per_tag[date] = { value: entry[:val].to_f, filed: filed, form: entry[:form], tag: name }
          end
        end
        per_tag.each { |date, row| out[date] ||= row }
      end
      out
    end

    # Year-end values for a balance-sheet concept (fiscal-year 10-K instants).
    def instant_values(facts, names)
      dated = {}
      instant_entries(facts, names).each do |date, row|
        year = fiscal_year(date)
        dated[year] = [date, row[:value]] if !dated.key?(year) || date > dated[year][0]
      end
      dated.transform_values(&:last)
    end

    # The most recent balance sheet in the facts, 10-K or 10-Q, every component
    # read at that one date (in millions). This is what an EV bridge needs: the
    # reference loader bridged a current price through the last fiscal year
    # end, which for Itron missed a $600m convertible and a buyback filed since.
    #
    # Gross debt is the current plus non-current lines when either is tagged,
    # else a total-debt tag; when no debt line exists at that date it is taken
    # as zero WITH `debt_note` saying so, because a filer with no debt tags at
    # all is usually debt-free but not always. Non-controlling interest and
    # preferred equity are read for the bridge (zero when absent).
    def latest_balance_sheet(facts)
      cash_by_date = instant_entries(facts, INSTANT_TAGS[:cash], forms: BALANCE_FORMS, fiscal_year_only: false)
      return nil if cash_by_date.empty?

      as_of = cash_by_date.keys.max
      at = lambda do |key|
        row = instant_entries(facts, INSTANT_TAGS[key], forms: BALANCE_FORMS, fiscal_year_only: false)[as_of]
        row && row[:value]
      end
      cash = cash_by_date[as_of][:value]
      short_term_investments = at.call(:short_term_investments) || 0.0
      debt_current = at.call(:debt_current)
      debt_noncurrent = at.call(:debt_noncurrent)
      debt_total = at.call(:debt_total)
      debt_note = nil
      gross_debt =
        if debt_current || debt_noncurrent
          (debt_current || 0.0) + (debt_noncurrent || 0.0)
        elsif debt_total
          debt_total
        else
          debt_note = "No debt line tagged at #{as_of.iso8601}; gross debt taken as zero."
          0.0
        end
      minority_interest = at.call(:minority_interest) || 0.0
      preferred_equity = at.call(:preferred_equity) || 0.0
      millions = ->(value) { value.nil? ? nil : py_round(value / 1e6, 1) }
      {
        as_of: as_of,
        form: cash_by_date[as_of][:form],
        cash: millions.call(cash),
        short_term_investments: millions.call(short_term_investments),
        debt_current: millions.call(debt_current),
        debt_noncurrent: millions.call(debt_noncurrent),
        debt_total: millions.call(debt_total),
        gross_debt: millions.call(gross_debt),
        minority_interest: millions.call(minority_interest),
        preferred_equity: millions.call(preferred_equity),
        net_debt: millions.call(gross_debt - cash - short_term_investments),
        debt_note: debt_note
      }
    end

    # Shares outstanding from the most recent filing cover page.
    def cover_shares(facts)
      entries = facts.dig(:facts, :dei, :EntityCommonStockSharesOutstanding, :units, :shares) || []
      return nil if entries.empty?

      latest = entries.max_by { |row| [row[:end].to_s, row[:filed].to_s] }
      latest[:val].to_f
    end

    # Diluted and basic share counts, in shares (not millions), with `basis`
    # saying which count `diluted` really is.
    #
    # `diluted` is the latest annual weighted-average diluted count: per-share
    # values in a bridge divide by diluted shares, and the Python loader's use of
    # the cover-page count under a "diluted" label understated them by ~6% for
    # Itron (43.79m vs 46.32m). `basic` is the cover-page count. Two guards an
    # audit of 600 filers showed were needed: the weighted count must belong to
    # the latest fiscal year on file (a tag a filer stopped using left
    # LyondellBasell with a count from 2011), and it must be of the cover
    # count's order of magnitude (McDonald's tags the count in millions, which
    # read as 716 shares). Either failure falls back to the cover page. Multi-
    # class filers report the cover-page count per class as dimensional facts,
    # which the companyfacts feed omits, so `diluted` then stands alone and
    # `basic` stays nil rather than borrowing it.
    def shares(facts)
      cover = cover_shares(facts)
      cover = nil if cover&.zero?
      diluted = duration_entries(facts, TAGS[:diluted_shares], unit: "shares")
      latest_year = duration_values(facts, TAGS[:revenue]).keys.max
      year = diluted.keys.max
      weighted = year && diluted[year][:value]
      weighted = nil if weighted&.zero?
      reason = nil
      if weighted && latest_year && year < latest_year
        reason = "diluted count is from FY#{year}, revenue runs to FY#{latest_year}"
        weighted = nil
      elsif weighted && cover && !(0.5..2.0).cover?(weighted / cover)
        reason = "diluted count #{weighted.round} is off-scale against the cover page #{cover.round}"
        weighted = nil
      end
      basis =
        if weighted then "weighted_diluted"
        elsif cover then "cover_page"
        else "none"
        end
      { diluted: weighted || cover, basic: cover, basis: basis, fallback_reason: reason }
    end

    # Annual income-statement and cash-flow rows, newest `years` fiscal years,
    # followed by one trailing-twelve-month row when a 10-Q extends the last
    # year (see ltm_row).
    #
    # Amounts are converted to millions to match the rest of the application.
    def build_financials(facts, years: 6)
      entries = TAGS.each_with_object({}) do |(key, names), out|
        out[key] = duration_entries(facts, names, sub_line_guard: key == :revenue) unless key == :eps
      end
      series = entries.transform_values { |rows| rows.transform_values { |row| row[:value] } }
      if series[:dep_amort].empty?
        # Some filers (Badger Meter, for one) never tag a combined line.
        depreciation = duration_values(facts, %w[Depreciation])
        amortisation = duration_values(facts, %w[AmortizationOfIntangibleAssets])
        series[:dep_amort] = (depreciation.keys | amortisation.keys).to_h do |year|
          [year, depreciation.fetch(year, 0.0) + amortisation.fetch(year, 0.0)]
        end
      end
      eps = duration_values(facts, TAGS[:eps], unit: "USD/shares")
      balance = INSTANT_TAGS.transform_values { |names| instant_values(facts, names) }

      available = series[:revenue].keys.sort.last(years)
      rows = []
      available.each do |year|
        revenue = series[:revenue][year]
        next if revenue.nil? || revenue.zero?

        operating_income = series[:operating_income][year]
        dep_amort = series[:dep_amort][year]
        ebitda = operating_income && dep_amort ? operating_income + dep_amort : nil
        pretax = series[:pretax_income][year]
        tax = series[:income_tax][year]
        tax_rate = nil
        tax_rate = (tax / pretax).clamp(0.0, 0.5) if pretax && tax && pretax.positive?

        working_capital = operating_working_capital(balance, year)
        prior_working_capital = operating_working_capital(balance, year - 1)
        nwc_change =
          working_capital && prior_working_capital ? (working_capital - prior_working_capital) / 1e6 : nil

        rows << {
          fiscal_year: year,
          period_type: "FY",
          period_end: entries[:revenue][year][:period_end],
          is_estimate: false,
          revenue: py_round(revenue / 1e6, 1),
          ebitda: ebitda ? py_round(ebitda / 1e6, 1) : nil,
          ebit: operating_income ? py_round(operating_income / 1e6, 1) : nil,
          net_income: series[:net_income].key?(year) ? py_round(series[:net_income][year] / 1e6, 1) : nil,
          eps: eps.key?(year) ? py_round(eps[year], 2) : nil,
          dep_amort: dep_amort ? py_round(dep_amort / 1e6, 1) : nil,
          capex: series[:capex].key?(year) ? py_round(series[:capex][year] / 1e6, 1) : nil,
          nwc_change: nwc_change ? py_round(nwc_change, 1) : nil,
          tax_rate: tax_rate ? py_round(tax_rate, 4) : nil
        }
      end
      unless rows.empty?
        last_year = rows.last[:fiscal_year]
        fy_tags = entries.to_h { |key, by_year| [key, by_year.dig(last_year, :tag)] }.compact
        ltm = ltm_row(facts, rows.last, fy_tags: fy_tags)
        rows << ltm if ltm
      end
      rows
    end

    # Trailing twelve months to the latest 10-Q after the last fiscal year:
    # fiscal year + current year-to-date − prior-year year-to-date, per flow.
    # Bankers quote LTM (and NTM) multiples, not last-fiscal-year ones; the
    # reference loader stored annual rows only, so Itron's multiples sat on a
    # year that had ended nine months before the pricing date.
    #
    # EPS is rolled the same way (an approximation when the share count moved).
    # D&A falls back to the fiscal-year figure when the quarterlies do not tag
    # it, since it barely moves within a year. Working capital is not rolled.
    # Returns nil when no 10-Q extends the last fiscal year or the prior-year
    # comparable is missing.
    def ltm_row(facts, fy_row, fy_tags: {})
      fy_end = fy_row[:period_end]
      # The year-to-date figure must come from the tag the fiscal-year figure
      # came from, or FY + YTD − prior YTD mixes two definitions of the line.
      tags_for = ->(key) { ([fy_tags[key]] + TAGS[key]).compact.uniq }
      revenue = latest_ytd(facts, tags_for.call(:revenue), after: fy_end)
      return nil if revenue.nil? || revenue[:prior_value].nil?

      quarter_end = revenue[:period_end]
      ytd = { revenue: revenue }
      %i[operating_income dep_amort net_income capex].each do |key|
        ytd[key] = latest_ytd(facts, tags_for.call(key), after: fy_end, period_end: quarter_end)
      end
      ytd[:eps] = latest_ytd(facts, tags_for.call(:eps), unit: "USD/shares", after: fy_end, period_end: quarter_end)

      roll = lambda do |key, fy_value, scale|
        y = ytd[key]
        next nil if y.nil? || y[:prior_value].nil? || fy_value.nil?

        fy_value + (y[:value] - y[:prior_value]) / scale
      end
      ltm_revenue = roll.call(:revenue, fy_row[:revenue], 1e6)
      ebit = roll.call(:operating_income, fy_row[:ebit], 1e6)
      dep_amort = roll.call(:dep_amort, fy_row[:dep_amort], 1e6) || fy_row[:dep_amort]
      {
        fiscal_year: fy_row[:fiscal_year],
        period_type: "LTM",
        period_end: quarter_end,
        is_estimate: false,
        revenue: py_round(ltm_revenue, 1),
        ebitda: ebit && dep_amort ? py_round(ebit + dep_amort, 1) : nil,
        ebit: ebit ? py_round(ebit, 1) : nil,
        net_income: (v = roll.call(:net_income, fy_row[:net_income], 1e6)) ? py_round(v, 1) : nil,
        eps: (v = roll.call(:eps, fy_row[:eps], 1.0)) ? py_round(v, 2) : nil,
        dep_amort: dep_amort ? py_round(dep_amort, 1) : nil,
        capex: (v = roll.call(:capex, fy_row[:capex], 1e6)) ? py_round(v, 1) : nil,
        nwc_change: nil,
        tax_rate: fy_row[:tax_rate]
      }
    end

    # The latest year-to-date 10-Q observation of a duration concept ending
    # after `after` (and exactly on `period_end` when given), with the
    # prior-year comparable of the same span: {quarter:, period_start:,
    # period_end:, value:, prior_value:, tag:} or nil. First tag with a
    # qualifying current period wins.
    def latest_ytd(facts, names, unit: "USD", after:, period_end: nil)
      us_gaap = facts.dig(:facts, :"us-gaap") || {}
      names.each do |name|
        durations = (us_gaap.dig(name.to_sym, :units, unit.to_sym) || []).select { |e| e[:start].present? && e[:end].present? }
        current = durations.filter_map do |entry|
          next unless QUARTERLY_FORMS.include?(entry[:form])

          start = Date.iso8601(entry[:start])
          finish = Date.iso8601(entry[:end])
          quarter = YTD_SPANS.find { |_q, span| span.cover?((finish - start).to_i) }&.first
          next if quarter.nil? || finish <= after
          next if period_end && finish != period_end

          [entry, start, finish, quarter]
        end
        next if current.empty?

        entry, start, finish, quarter = current.max_by { |e, _s, f, _q| [f, e[:filed].to_s] }
        prior = durations.select do |e|
          near?(Date.iso8601(e[:end]), finish << 12) && near?(Date.iso8601(e[:start]), start << 12)
        end.max_by { |e| e[:filed].to_s }
        return {
          quarter: quarter, period_start: start, period_end: finish,
          value: entry[:val].to_f, prior_value: prior && prior[:val].to_f, tag: name
        }
      end
      nil
    end

    def near?(date, target, days: 10)
      (date - target).abs <= days
    end

    # Current assets less cash, minus current liabilities less debt.
    #
    # Using raw current assets and liabilities would count a convertible note
    # moving into "current" as a working-capital release — a real bug this
    # replaced, which once added the whole note to every projected cash flow.
    def operating_working_capital(balance, year)
      return nil unless balance[:assets_current].key?(year) && balance[:liabilities_current].key?(year)

      assets = balance[:assets_current][year] -
               balance[:cash].fetch(year, 0.0) -
               balance[:short_term_investments].fetch(year, 0.0)
      liabilities = balance[:liabilities_current][year] - balance[:debt_current].fetch(year, 0.0)
      assets - liabilities
    end

    # Gross debt less cash and short-term investments at a fiscal year end, in
    # millions (the latest_balance_sheet is what the loader stores; this is the
    # year-end view the financial history and tests use).
    def net_debt(facts, fiscal_year)
      balance = INSTANT_TAGS.transform_values { |names| instant_values(facts, names) }
      debt = balance[:debt_current].fetch(fiscal_year, 0.0) + balance[:debt_noncurrent].fetch(fiscal_year, 0.0)
      cash = balance[:cash][fiscal_year]
      return nil if cash.nil? && debt.zero?

      liquid = (cash || 0.0) + balance[:short_term_investments].fetch(fiscal_year, 0.0)
      py_round((debt - liquid) / 1e6, 1)
    end

    # --------------------------------------------------------------- documents

    # The submissions feed is column-oriented; one hash per filing is easier to
    # reason about. Keys keep the SEC's own camelCase names.
    def recent_filings(submissions)
      recent = submissions.dig(:filings, :recent) || {}
      columns = FILING_COLUMNS.to_h { |key| [key, recent[key] || []] }
      Array.new(columns[:form].length) do |index|
        FILING_COLUMNS.to_h { |key| [key, columns[key][index]] }
      end
    end

    # The earnings release exhibit (EX-99.1) inside an 8-K, when present.
    #
    # Filers name the file however their agent likes — exh_991.htm,
    # bmi-ex99_pressrelease.htm, d12345dex991.htm — so the match runs on the
    # name with punctuation removed and prefers an explicit 99.1.
    def exhibit_url(cik, accession)
      base = format(ARCHIVE_BASE, cik: Integer(cik, 10), accession: accession)
      index =
        begin
          Http.fetch_json("#{base}/index.json")
        rescue StandardError
          return nil
        end
      candidates = []
      (index.dig(:directory, :item) || []).each do |item|
        name = item[:name].to_s
        next unless name.downcase.end_with?(".htm", ".html", ".txt")

        normalised = name.downcase.gsub(/[^a-z0-9]/, "")
        next unless normalised.include?("ex99") || normalised.include?("exh99")

        priority = normalised.include?("ex991") || normalised.include?("exh991") ? 0 : 1
        candidates << [priority, name]
      end
      return nil if candidates.empty?

      "#{base}/#{candidates.min[1]}"
    end

    # Fetch filing text and return records ready for `Ingest.ingest_many`.
    #
    # Dates stay ISO strings here, as in the Python records: these hashes are the
    # same shape `Ingest.read_documents` yields from .json/.csv files.
    def collect_documents(cik, submissions, annual: 1, quarterly: 2, press_releases: 4)
      company_name = title_case(submissions[:name].to_s)
      ticker = submissions[:tickers]&.first
      wanted = { "10-K" => annual, "10-Q" => quarterly, "8-K" => press_releases }
      collected = []
      counts = wanted.transform_values { 0 }

      recent_filings(submissions).each do |filing|
        form = filing[:form]
        next if !wanted.key?(form) || counts[form] >= wanted[form]

        accession = filing[:accessionNumber].to_s.delete("-")
        next if accession.empty?

        base = format(ARCHIVE_BASE, cik: Integer(cik, 10), accession: accession)
        if form == "8-K"
          url = exhibit_url(cik, accession)
          next unless url # an 8-K with no earnings release is not research material
        else
          next if filing[:primaryDocument].blank?

          url = "#{base}/#{filing[:primaryDocument]}"
        end

        text =
          begin
            HtmlText.html_to_text(Http.fetch(url), max_chars: MAX_FILING_CHARS)
          rescue StandardError
            next
          end
        next if text.length < MIN_DOCUMENT_CHARS

        period = filing[:reportDate].presence || filing[:filingDate]
        label = FORM_LABELS.fetch(form, "Earnings Release (8-K)")
        collected << {
          external_id: "#{accession}-#{form}",
          title: "#{company_name} #{label} — #{period}",
          ticker: ticker,
          company_name: company_name,
          doc_type: FORM_DOC_TYPES[form],
          source: "SEC EDGAR",
          author: company_name,
          published_at: filing[:filingDate],
          period: period,
          url: url,
          body: text
        }
        counts[form] += 1
      end
      collected
    end

    # Python's str.title(): "ITRON INC" -> "Itron Inc", "O'NEIL" -> "O'Neil",
    # "3M CO" -> "3M Co". Rails' titleize has other ideas about underscores and
    # acronyms, so the rule is written out.
    def title_case(text)
      text.gsub(/[[:alpha:]]+/, &:capitalize)
    end

    # ------------------------------------------------------------------ loader

    # Load one real company: profile, financials, market data and filings.
    def load_company(
      ticker, sector: nil, years: 6, annual: 1, quarterly: 2, press_releases: 4,
      with_documents: true, with_quote: true, with_estimates: true
    )
      cik = resolve_cik(ticker)
      raise ArgumentError, "no SEC filer found for ticker #{ticker.upcase}" unless cik

      submissions = fetch_submissions(cik)
      facts = fetch_facts(cik)
      addresses = submissions.dig(:addresses, :business) || {}
      name = title_case(submissions[:name].presence || ticker)

      financial_rows = build_financials(facts, years: years)
      fiscal_rows = financial_rows.select { |row| row[:period_type] == "FY" }
      ltm = financial_rows.find { |row| row[:period_type] == "LTM" }
      quote = with_quote ? Market.fetch_quote(ticker) : nil
      estimates = with_estimates ? Market.fetch_estimates(ticker) : nil
      share_counts = shares(facts)
      balance = latest_balance_sheet(facts)
      latest_fiscal_year = fiscal_rows.last&.fetch(:fiscal_year)
      # Consensus rows for the fiscal years not yet reported, so the valuation
      # can quote NTM multiples beside LTM. No consensus EBITDA is published
      # here; Valuation derives it from consensus revenue at the LTM margin and
      # says so.
      estimate_rows = (estimates ? estimates[:estimates] : []).select do |row|
        latest_fiscal_year.nil? || row[:fiscal_year] > latest_fiscal_year
      end.map do |row|
        { fiscal_year: row[:fiscal_year], period_type: "FY", period_end: row[:period_end], is_estimate: true,
          revenue: row[:revenue], eps: row[:eps], estimate_source: row[:source] }
      end

      company = nil
      ActiveRecord::Base.transaction do
        company = Company.upsert_by_ticker!(
          ticker: ticker.upcase,
          name: name,
          sector: sector || submissions[:sicDescription].presence || "Unclassified",
          industry: submissions[:sicDescription],
          country: addresses[:stateOrCountryDescription].presence || "United States",
          hq: [addresses[:city], addresses[:stateOrCountry]].select(&:present?).join(", "),
          currency: "USD",
          description: "#{name} (CIK #{Integer(cik, 10)}, SIC #{submissions[:sic]} — #{submissions[:sicDescription]}). " \
                       "Profile, financials and filings loaded from SEC EDGAR."
        )

        # Replace rather than merge: a restated year must not leave stale rows.
        company.financials.delete_all
        financial_rows.each { |row| company.financials.create!(row) }
        estimate_rows.each { |row| company.financials.create!(row) }

        if quote && share_counts[:diluted]
          MarketDatum.where(company_id: company.id).delete_all
          MarketDatum.create!(
            company: company,
            as_of: quote[:as_of] || Date.today,
            share_price: quote[:share_price],
            shares_diluted: py_round(share_counts[:diluted] / 1e6, 2), # millions, as elsewhere
            shares_basic: share_counts[:basic] ? py_round(share_counts[:basic] / 1e6, 2) : nil,
            # The latest balance sheet (10-K or 10-Q), dated, with the other
            # claims the EV bridge deducts — not the last fiscal year end.
            net_debt: balance && balance[:net_debt],
            net_debt_as_of: balance && balance[:as_of],
            balance_sheet_form: balance && balance[:form],
            minority_interest: balance && balance[:minority_interest],
            preferred_equity: balance && balance[:preferred_equity],
            debt_note: balance && balance[:debt_note],
            week52_low: quote[:week52_low],
            week52_high: quote[:week52_high],
            beta: estimates && estimates[:beta]
          )
        end
      end

      documents =
        if with_documents
          collect_documents(cik, submissions, annual: annual, quarterly: quarterly, press_releases: press_releases)
        else
          []
        end
      ingested = documents.empty? ? { added: 0, skipped: 0 } : Ingest.ingest_many(documents)

      {
        ticker: ticker.upcase,
        name: name,
        cik: cik,
        fiscal_years: fiscal_rows.map { |row| row[:fiscal_year] },
        latest_revenue: fiscal_rows.last&.fetch(:revenue),
        ltm_period_end: ltm && ltm[:period_end],
        shares_basis: share_counts[:basis],
        net_debt_as_of: balance && balance[:as_of],
        estimate_years: estimate_rows.map { |row| row[:fiscal_year] },
        beta: estimates && estimates[:beta],
        share_price: quote ? quote[:share_price] : nil,
        # The quote cache refreshes daily; saying which day the price is from
        # lets a reader tell a fresh load from one served out of the cache.
        quote_as_of: quote ? quote[:as_of] : nil,
        documents_added: ingested[:added],
        documents_skipped: ingested[:skipped]
      }
    end

    # Load several companies, reporting per-ticker results and any failures.
    def load_companies(tickers, **opts)
      loaded = []
      failures = []
      tickers.each do |ticker|
        loaded << load_company(ticker, **opts)
      rescue StandardError => e # one bad ticker must not sink the batch
        failures << { ticker: ticker.upcase, error: "#{e.class.name}: #{e.message}" }
      end
      {
        loaded: loaded,
        failures: failures,
        companies: loaded.size,
        documents_added: loaded.sum { |row| row[:documents_added] }
      }
    end

    # Load precedent transactions from a CSV you supply.
    #
    # Deal multiples are not in EDGAR in any consistent, machine-readable form, so
    # this is the hook for a licensed screen or your own deal log. Columns:
    # announced_on, target, acquirer, sector, ev, ev_revenue, ev_ebitda,
    # premium_1day, consideration, note.
    def load_transactions_csv(path)
      rows = CSV.read(path.to_s, headers: true, encoding: "bom|utf-8")
      added = 0
      ActiveRecord::Base.transaction do
        rows.each do |row|
          next if row["announced_on"].blank? || row["target"].blank?

          payload = {
            announced_on: Date.iso8601(row["announced_on"][0, 10]),
            target: row["target"],
            acquirer: row["acquirer"].presence || "Undisclosed",
            sector: row["sector"].presence,
            note: row["note"].presence,
            consideration: row["consideration"].presence
          }
          %w[ev ev_revenue ev_ebitda premium_1day].each do |key|
            value = row[key].to_s.strip
            payload[key.to_sym] = value.empty? ? nil : Float(value)
          end
          Transaction.create!(payload)
          added += 1
        end
      end
      { added: added, rows: rows.size }
    end

    # Python's round(x, n) rounds the *exact* binary value half-to-even; Ruby's
    # Float#round rounds the shortest decimal rendering half-up, so figures
    # reported in thousands land on a tie once in a hundred and drift by 0.1m
    # (1,234,550 thousand -> 1234.6 here, 1234.5 in the reference). The stored
    # fundamentals must match the Python loader to the last digit, as Nlp and
    # Valuation already do, so every rounded output goes through here.
    def py_round(value, digits)
      float = value.to_f
      return float unless float.finite?

      scale = 10**digits
      Rational((float.to_r * scale).round(half: :even), scale).to_f
    end
  end
end
