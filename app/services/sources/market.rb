# frozen_string_literal: true

module Sources
  # Public market quotes.
  #
  # Share price, 52-week range and beta come from a public quote endpoint; shares
  # outstanding come from the filer's own cover page in EDGAR, because that is
  # the authoritative number and it arrives with the rest of the fundamentals.
  module Market
    QUOTE_URL = "https://query1.finance.yahoo.com/v8/finance/chart/%<ticker>s?range=1y&interval=1d"
    # A browser-ish agent: the quote endpoint rejects the SEC-style identifier.
    QUOTE_USER_AGENT = "Mozilla/5.0 (compatible; Argos-Research-Tool/1.0)"

    module_function

    # Return price, 52-week range and currency for a ticker, or nil.
    #
    # `as_of` is a Date (ISO strings only at the API boundary).
    def fetch_quote(ticker, cache: true, on: Date.today)
      payload =
        begin
          Http.fetch_json(quote_url(ticker, on: on), cache: cache, user_agent: QUOTE_USER_AGENT)
        rescue StandardError
          return nil
        end
      results = payload.dig(:chart, :result) || []
      return nil if results.empty?

      meta = results[0][:meta] || {}
      price = meta[:regularMarketPrice]
      return nil if price.nil?

      # Fall back to the year of closes when the summary range is absent.
      quote = (results[0].dig(:indicators, :quote) || [])[0] || {}
      closes = (quote[:close] || []).compact
      low = truthy(meta[:fiftyTwoWeekLow]) || closes.min
      high = truthy(meta[:fiftyTwoWeekHigh]) || closes.max
      {
        ticker: meta.fetch(:symbol, ticker.upcase),
        share_price: price.to_f.round(2),
        currency: meta.fetch(:currency, "USD"),
        week52_low: truthy(low) ? low.to_f.round(2) : nil,
        week52_high: truthy(high) ? high.to_f.round(2) : nil,
        as_of: as_of(meta),
        exchange: meta[:fullExchangeName]
      }
    end

    # The disk cache is keyed by URL, so the calendar day rides along as a query
    # parameter the endpoint ignores; without it a cached quote was served
    # forever and "re-run the loader to refresh" was false.
    def quote_url(ticker, on: Date.today)
      "#{format(QUOTE_URL, ticker: ticker.upcase)}&asof=#{on.iso8601}"
    end

    # Python's `or` on a number: nil and zero both fall through to the fallback.
    def truthy(value)
      value.nil? || value == 0 ? nil : value
    end

    def as_of(meta)
      stamp = meta[:regularMarketTime]
      return nil if stamp.nil? || stamp == 0

      Time.at(Integer(stamp)).utc.to_date
    end
  end
end
