# frozen_string_literal: true

module Backtest
  # Every filed observation of the concepts the backtest needs, with the date
  # it became public. Restatements are kept as their own rows.
  module Fundamentals
    FACTS_URL = Sources::Sec::FACTS_URL
    FORMS = %w[10-K 10-K/A 10-Q 10-Q/A].freeze
    EARLIEST_PERIOD_END = Date.new(2013, 1, 1)

    # concept => [namespace, unit, kind, tags]. Tags are in preference order
    # and resolved PER PERIOD AND FILING: for each (period_end, filed) the
    # first tag that carries a value wins. Resolving once per company (the
    # first tag with any data) lost every later year for filers that switched
    # tags, and dropped names whose D&A sits under a less common tag.
    CONCEPTS = {
      "revenue" => ["us-gaap", "USD", :duration, Sources::Sec::TAGS[:revenue]],
      "operating_income" => ["us-gaap", "USD", :duration, Sources::Sec::TAGS[:operating_income]],
      "dep_amort" => ["us-gaap", "USD", :duration, Sources::Sec::TAGS[:dep_amort] + %w[DepreciationAmortizationAndOther]],
      "net_income" => ["us-gaap", "USD", :duration, Sources::Sec::TAGS[:net_income]],
      "eps" => ["us-gaap", "USD/shares", :duration, Sources::Sec::TAGS[:eps]],
      "shares_diluted" => ["us-gaap", "shares", :duration, Sources::Sec::TAGS[:diluted_shares]],
      "cash" => ["us-gaap", "USD", :instant, Sources::Sec::INSTANT_TAGS[:cash]],
      "short_term_investments" => ["us-gaap", "USD", :instant, Sources::Sec::INSTANT_TAGS[:short_term_investments]],
      "debt_current" => ["us-gaap", "USD", :instant, Sources::Sec::INSTANT_TAGS[:debt_current]],
      "debt_noncurrent" => ["us-gaap", "USD", :instant, Sources::Sec::INSTANT_TAGS[:debt_noncurrent]],
      # Total borrowings, current and non-current together, for filers that tag
      # neither split line (AT&T's LongTermDebt is the whole stack). The runner
      # uses it only when both split lines are missing.
      "debt_total" => ["us-gaap", "USD", :instant, %w[
        LongTermDebt DebtLongtermAndShorttermCombinedAmount DebtAndCapitalLeaseObligations DebtInstrumentCarryingAmount
      ]],
      "shares_cover" => ["dei", "shares", :instant, %w[EntityCommonStockSharesOutstanding]]
    }.freeze

    # Summed when a filer never tags a combined D&A line (Badger Meter, for one).
    DEP_AMORT_PARTS = %w[Depreciation AmortizationOfIntangibleAssets].freeze
    DEP_AMORT_SUM_TAG = DEP_AMORT_PARTS.join("+")

    # Span (days) that counts as a full year on a 10-K or a quarter on a 10-Q.
    ANNUAL_SPAN = (330..400)
    QUARTER_SPAN = (80..100)

    module_function

    def build!(anchor_year: 2016, cache: true, progress: nil)
      members = UniverseMember.where(anchor_year: anchor_year).order(:id)
      totals = { companies: 0, rows: 0, failures: [] }
      members.each_with_index do |member, index|
        facts = Sources::Http.fetch_json(format(FACTS_URL, cik: member.cik.to_s.rjust(10, "0")), cache: cache)
        rows = observations(facts, cik: member.cik, ticker: member.ticker)
        PitFact.where(cik: member.cik).delete_all
        rows.each_slice(500) { |slice| PitFact.insert_all(slice, unique_by: %i[cik concept period_end filed]) }
        totals[:companies] += 1
        totals[:rows] += rows.size
        progress&.call(index + 1, members.size, member.cik)
      rescue Sources::Http::Error, JSON::ParserError => e
        totals[:failures] << { cik: member.cik, error: e.message }
      end
      totals[:not_a_filer_in_anchor_year] = mark_non_filers!(anchor_year)
      totals
    end

    # All qualifying observations for one company's facts file.
    def observations(facts, cik:, ticker: nil)
      rows = []
      CONCEPTS.each do |concept, (namespace, unit, kind, tags)|
        seen = {}
        tags.each do |tag|
          entries(facts, namespace, tag, unit).each do |entry|
            row = observation(entry, kind: kind)
            next if row.nil?

            key = [row[:period_end], row[:filed]]
            next if seen[key] # a later tag for the same period and filing, or the same value in another context

            seen[key] = true
            rows << row.merge(cik: cik, ticker: ticker, concept: concept, tag: tag)
          end
        end
        rows.concat(summed_dep_amort(facts, seen, cik: cik, ticker: ticker)) if concept == "dep_amort"
      end
      rows
    end

    # One qualifying row (without identity columns), or nil.
    def observation(entry, kind:)
      return nil unless FORMS.include?(entry[:form])
      return nil if entry[:end].nil? || entry[:filed].nil? || entry[:val].nil?

      period_end = Date.iso8601(entry[:end])
      return nil if period_end < EARLIEST_PERIOD_END

      period_start = entry[:start] && Date.iso8601(entry[:start])
      return nil unless span_ok?(kind, entry[:form], period_start, period_end)

      {
        fiscal_year: entry[:fy], period_start: period_start, period_end: period_end,
        value: entry[:val].to_f, filed: Date.iso8601(entry[:filed]), accession: entry[:accn], form: entry[:form]
      }
    end

    def entries(facts, namespace, tag, unit)
      facts.dig(:facts, namespace.to_sym, tag.to_sym, :units, unit.to_sym) || []
    end

    # Depreciation + amortisation of intangibles for the (period, filing) pairs
    # that no combined tag covered.
    def summed_dep_amort(facts, seen, cik:, ticker:)
      depreciation, amortisation = DEP_AMORT_PARTS.map do |tag|
        entries(facts, "us-gaap", tag, "USD").filter_map { |entry| observation(entry, kind: :duration) }
                                              .to_h { |row| [[row[:period_end], row[:filed]], row] }
      end
      depreciation.filter_map do |key, dep|
        next if seen[key]

        amort = amortisation[key]
        next if amort.nil?

        seen[key] = true
        dep.merge(cik: cik, ticker: ticker, concept: "dep_amort", value: dep[:value] + amort[:value], tag: DEP_AMORT_SUM_TAG)
      end
    end

    def span_ok?(kind, form, period_start, period_end)
      return true if kind == :instant
      return false if period_start.nil?

      span = (period_end - period_start).to_i
      form.start_with?("10-K") ? ANNUAL_SPAN.cover?(span) : QUARTER_SPAN.cover?(span)
    end

    # A member with no filing before mid-way through the year after the anchor
    # did not exist as a registrant in the anchor year (a successor CIK after a
    # merger, a later IPO or spin-off): the frame carried its anchor-year figure
    # as a comparative in a later 10-K. docs/BACKTEST.md selects at the start
    # of the window, so these become dropouts with their own reason. Returns
    # the number of members so marked.
    def mark_non_filers!(anchor_year)
      cutoff = Date.new(anchor_year + 1, 6, 30)
      members = UniverseMember.where(anchor_year: anchor_year)
      filers = PitFact.where(cik: members.pluck(:cik)).where("filed <= ?", cutoff).distinct.pluck(:cik)
      members.where.not(cik: filers).where(dropout_reason: nil).update_all(dropout_reason: "not_a_filer_in_anchor_year")
      members.where(dropout_reason: "not_a_filer_in_anchor_year").count
    end
  end
end
