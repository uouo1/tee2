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

    # Annual values by fiscal year for a duration concept (P&L, cash flow).
    def duration_values(facts, names, unit: "USD")
      us_gaap = facts.dig(:facts, :"us-gaap") || {}
      out = {}
      names.each do |name|
        entries = us_gaap.dig(name.to_sym, :units, unit.to_sym) || []
        entries.each do |entry|
          next unless ANNUAL_FORMS.include?(entry[:form]) && entry[:fp] == "FY"

          start, finish = entry[:start], entry[:end]
          next if start.blank? || finish.blank?

          span = (Date.iso8601(finish) - Date.iso8601(start)).to_i
          next unless (330..400).cover?(span) # a full year, not a quarter or a stub

          year = fiscal_year(finish)
          filed = entry[:filed].to_s
          # Later filings restate earlier ones; keep the most recently filed.
          out[year] = [filed, entry[:val].to_f] if !out.key?(year) || filed > out[year][0]
        end
        break unless out.empty? # first tag that yields data wins the preference order
      end
      out.transform_values { |(_, value)| value }
    end

    # Year-end values for a balance-sheet concept.
    def instant_values(facts, names)
      us_gaap = facts.dig(:facts, :"us-gaap") || {}
      out = {}
      names.each do |name|
        (us_gaap.dig(name.to_sym, :units, :USD) || []).each do |entry|
          next unless ANNUAL_FORMS.include?(entry[:form]) && entry[:fp] == "FY"

          finish = entry[:end]
          next if finish.blank?

          year = fiscal_year(finish)
          filed = entry[:filed].to_s
          out[year] = [filed, entry[:val].to_f] if !out.key?(year) || filed > out[year][0]
        end
        break unless out.empty?
      end
      out.transform_values { |(_, value)| value }
    end

    # Shares outstanding from the most recent filing cover page.
    def cover_shares(facts)
      entries = facts.dig(:facts, :dei, :EntityCommonStockSharesOutstanding, :units, :shares) || []
      return nil if entries.empty?

      latest = entries.max_by { |row| [row[:end].to_s, row[:filed].to_s] }
      latest[:val].to_f
    end

    # Diluted and basic share counts, in shares (not millions).
    #
    # `diluted` is the latest annual weighted-average diluted count: per-share
    # values in a bridge divide by diluted shares, and the Python loader's use of
    # the cover-page count under a "diluted" label understated them by ~6% for
    # Itron (43.79m vs 46.32m). `basic` is the cover-page count. Multi-class
    # filers (Watts Water, for one) report the cover-page count per class as
    # dimensional facts, which the companyfacts feed omits, so each side falls
    # back to the other when it is missing.
    def shares(facts)
      cover = cover_shares(facts)
      cover = nil if cover&.zero?
      diluted = duration_values(facts, TAGS[:diluted_shares], unit: "shares")
      weighted = diluted.empty? ? nil : diluted[diluted.keys.max]
      { diluted: weighted || cover, basic: cover }
    end

    # Annual income-statement and cash-flow rows, newest `years` fiscal years.
    #
    # Amounts are converted to millions to match the rest of the application.
    def build_financials(facts, years: 6)
      series = TAGS.each_with_object({}) do |(key, names), out|
        out[key] = duration_values(facts, names) unless key == :eps
      end
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
          is_estimate: false,
          revenue: (revenue / 1e6).round(1),
          ebitda: ebitda ? (ebitda / 1e6).round(1) : nil,
          ebit: operating_income ? (operating_income / 1e6).round(1) : nil,
          net_income: series[:net_income].key?(year) ? (series[:net_income][year] / 1e6).round(1) : nil,
          eps: eps.key?(year) ? eps[year].round(2) : nil,
          dep_amort: dep_amort ? (dep_amort / 1e6).round(1) : nil,
          capex: series[:capex].key?(year) ? (series[:capex][year] / 1e6).round(1) : nil,
          nwc_change: nwc_change ? nwc_change.round(1) : nil,
          tax_rate: tax_rate ? tax_rate.round(4) : nil
        }
      end
      rows
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

    # Gross debt less cash and short-term investments, in millions.
    def net_debt(facts, fiscal_year)
      balance = INSTANT_TAGS.transform_values { |names| instant_values(facts, names) }
      debt = balance[:debt_current].fetch(fiscal_year, 0.0) + balance[:debt_noncurrent].fetch(fiscal_year, 0.0)
      cash = balance[:cash][fiscal_year]
      return nil if cash.nil? && debt.zero?

      liquid = (cash || 0.0) + balance[:short_term_investments].fetch(fiscal_year, 0.0)
      ((debt - liquid) / 1e6).round(1)
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
      with_documents: true, with_quote: true
    )
      cik = resolve_cik(ticker)
      raise ArgumentError, "no SEC filer found for ticker #{ticker.upcase}" unless cik

      submissions = fetch_submissions(cik)
      facts = fetch_facts(cik)
      addresses = submissions.dig(:addresses, :business) || {}
      name = title_case(submissions[:name].presence || ticker)

      financial_rows = build_financials(facts, years: years)
      latest_year = financial_rows.last&.fetch(:fiscal_year)
      quote = with_quote ? Market.fetch_quote(ticker) : nil
      share_counts = shares(facts)

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

        if quote && share_counts[:diluted]
          MarketDatum.where(company_id: company.id).delete_all
          MarketDatum.create!(
            company: company,
            as_of: quote[:as_of] || Date.today,
            share_price: quote[:share_price],
            shares_diluted: (share_counts[:diluted] / 1e6).round(2), # millions, as elsewhere
            shares_basic: share_counts[:basic] ? (share_counts[:basic] / 1e6).round(2) : nil,
            net_debt: latest_year ? net_debt(facts, latest_year) : nil,
            week52_low: quote[:week52_low],
            week52_high: quote[:week52_high],
            beta: nil
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
        fiscal_years: financial_rows.map { |row| row[:fiscal_year] },
        latest_revenue: financial_rows.last&.fetch(:revenue),
        share_price: quote ? quote[:share_price] : nil,
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
  end
end
