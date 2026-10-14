# frozen_string_literal: true

module Sources
  # EDGAR "frames": one concept, one calendar period, every filer.
  #
  # A single request returns the value each reporting entity last filed for
  # the period, which makes frames the cheap way to build a universe. They
  # carry no filing date, so they are never used as point-in-time inputs —
  # see docs/BACKTEST.md.
  module Frames
    FRAME_URL = "https://data.sec.gov/api/xbrl/frames/us-gaap/%<tag>s/USD/%<period>s.json"
    REVENUE_TAGS = %w[
      Revenues
      RevenueFromContractWithCustomerExcludingAssessedTax
      SalesRevenueNet
    ].freeze

    module_function

    # Rows for one tag and period ("CY2016" for a year, "CY2016Q4I" for an instant).
    def fetch(tag, period, cache: true)
      payload = Http.fetch_json(format(FRAME_URL, tag: tag, period: period), cache: cache)
      (payload[:data] || []).map do |row|
        {
          cik: row[:cik].to_i, entity_name: row[:entityName], loc: row[:loc],
          start: row[:start], end: row[:end], val: row[:val]&.to_f, accn: row[:accn], tag: tag
        }
      end
    rescue Http::HttpError => e
      raise unless e.status == 404 # a tag nobody used that year is an empty frame, not an error

      []
    end

    # Calendar-year revenue by CIK, taking the first tag that reports for each
    # filer. Tags are tried in REVENUE_TAGS order because filers moved between
    # them over the decade and a frame per tag only lists its own adopters.
    def revenue_by_cik(year, tags: REVENUE_TAGS, cache: true)
      merged = {}
      tags.each do |tag|
        fetch(tag, "CY#{year}", cache: cache).each do |row|
          next if row[:val].nil? || merged.key?(row[:cik])

          merged[row[:cik]] = row
        end
      end
      merged
    end
  end
end
