# frozen_string_literal: true

module Backtest
  # Every filed observation of the concepts the backtest needs, with the date
  # it became public. Restatements are kept as their own rows.
  module Fundamentals
    FACTS_URL = Sources::Sec::FACTS_URL
    FORMS = %w[10-K 10-K/A 10-Q 10-Q/A].freeze
    EARLIEST_PERIOD_END = Date.new(2013, 1, 1)

    # concept => [namespace, unit, kind, tags]
    CONCEPTS = {
      "revenue" => ["us-gaap", "USD", :duration, Sources::Sec::TAGS[:revenue]],
      "operating_income" => ["us-gaap", "USD", :duration, Sources::Sec::TAGS[:operating_income]],
      "dep_amort" => ["us-gaap", "USD", :duration, Sources::Sec::TAGS[:dep_amort]],
      "net_income" => ["us-gaap", "USD", :duration, Sources::Sec::TAGS[:net_income]],
      "eps" => ["us-gaap", "USD/shares", :duration, Sources::Sec::TAGS[:eps]],
      "shares_diluted" => ["us-gaap", "shares", :duration, Sources::Sec::TAGS[:diluted_shares]],
      "cash" => ["us-gaap", "USD", :instant, Sources::Sec::INSTANT_TAGS[:cash]],
      "short_term_investments" => ["us-gaap", "USD", :instant, Sources::Sec::INSTANT_TAGS[:short_term_investments]],
      "debt_current" => ["us-gaap", "USD", :instant, Sources::Sec::INSTANT_TAGS[:debt_current]],
      "debt_noncurrent" => ["us-gaap", "USD", :instant, Sources::Sec::INSTANT_TAGS[:debt_noncurrent]],
      "shares_cover" => ["dei", "shares", :instant, %w[EntityCommonStockSharesOutstanding]]
    }.freeze

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
      totals
    end

    # All qualifying observations for one company's facts file.
    def observations(facts, cik:, ticker: nil)
      rows = []
      CONCEPTS.each do |concept, (namespace, unit, kind, tags)|
        entries, tag = first_tag_with_data(facts, namespace, tags, unit)
        next if entries.empty?

        seen = {}
        entries.each do |entry|
          next unless FORMS.include?(entry[:form])
          next if entry[:end].nil? || entry[:filed].nil? || entry[:val].nil?

          period_end = Date.iso8601(entry[:end])
          next if period_end < EARLIEST_PERIOD_END

          period_start = entry[:start] && Date.iso8601(entry[:start])
          next unless span_ok?(kind, entry[:form], period_start, period_end)

          filed = Date.iso8601(entry[:filed])
          key = [period_end, filed]
          next if seen[key] # the same value reported in several contexts of one filing

          seen[key] = true
          rows << {
            cik: cik, ticker: ticker, concept: concept, fiscal_year: entry[:fy],
            period_start: period_start, period_end: period_end, value: entry[:val].to_f,
            filed: filed, accession: entry[:accn], form: entry[:form], tag: tag
          }
        end
      end
      rows
    end

    def first_tag_with_data(facts, namespace, tags, unit)
      bucket = facts.dig(:facts, namespace.to_sym) || {}
      tags.each do |tag|
        entries = bucket.dig(tag.to_sym, :units, unit.to_sym) || []
        return [entries, tag] if entries.any?
      end
      [[], nil]
    end

    def span_ok?(kind, form, period_start, period_end)
      return true if kind == :instant
      return false if period_start.nil?

      span = (period_end - period_start).to_i
      form.start_with?("10-K") ? ANNUAL_SPAN.cover?(span) : QUARTER_SPAN.cover?(span)
    end
  end
end
