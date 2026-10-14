# frozen_string_literal: true

module Backtest
  # The companies a backtest is allowed to look at, chosen at the START of the
  # window so that names which later failed are in the set (docs/BACKTEST.md).
  module Universe
    TICKER_INDEX_URL = Sources::Sec::TICKER_INDEX_URL
    SUBMISSIONS_URL = Sources::Sec::SUBMISSIONS_URL

    module_function

    # Build universe_members for `anchor_year`: top `size` US filers by that
    # year's revenue, joined to current tickers and sector codes.
    def build!(anchor_year: 2016, size: 600, cache: true, with_submissions: true, progress: nil)
      revenue = Sources::Frames.revenue_by_cik(anchor_year, cache: cache)
      ranked = revenue.values
                      .select { |row| row[:loc].to_s.start_with?("US-") && row[:val].to_f.positive? }
                      .sort_by { |row| -row[:val] }
                      .first(size)
      tickers = ticker_map(cache: cache)

      UniverseMember.where(anchor_year: anchor_year).delete_all
      now = Time.current
      ranked.each_with_index do |row, index|
        ticker = tickers[row[:cik]]
        attrs = {
          cik: row[:cik], ticker: ticker, name: row[:entity_name], loc: row[:loc],
          revenue_anchor: row[:val], anchor_year: anchor_year, selected_at: now,
          dropout_reason: ticker ? nil : "no_current_ticker"
        }
        if with_submissions
          attrs.merge!(sector_attributes(row[:cik], cache: cache))
        end
        UniverseMember.create!(attrs)
        progress&.call(index + 1, ranked.size, row[:cik])
      end
      summary(anchor_year)
    end

    # CIK -> ticker from the SEC index. Multi-class filers list several; the
    # first (the primary listing) is kept.
    def ticker_map(cache: true)
      index = Sources::Http.fetch_json(TICKER_INDEX_URL, cache: cache)
      map = {}
      index.values.sort_by { |row| row[:ticker].to_s.length }.each do |row|
        cik = row[:cik_str].to_i
        map[cik] ||= row[:ticker].to_s.upcase
      end
      map
    end

    def sector_attributes(cik, cache: true)
      submissions = Sources::Http.fetch_json(format(SUBMISSIONS_URL, cik: cik.to_s.rjust(10, "0")), cache: cache)
      {
        sic: submissions[:sic].to_s.presence,
        sic_description: submissions[:sicDescription],
        exchange: Array(submissions[:exchanges]).first,
        name: submissions[:name].presence
      }.compact
    rescue Sources::Http::Error
      {}
    end

    def summary(anchor_year)
      members = UniverseMember.where(anchor_year: anchor_year)
      {
        anchor_year: anchor_year,
        members: members.count,
        with_ticker: members.where.not(ticker: nil).count,
        no_current_ticker: members.where(dropout_reason: "no_current_ticker").count,
        median_revenue_anchor: median(members.pluck(:revenue_anchor).compact)
      }
    end

    def median(values)
      return nil if values.empty?

      sorted = values.sort
      mid = sorted.length / 2
      sorted.length.odd? ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2.0
    end
  end
end
