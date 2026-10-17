# frozen_string_literal: true

require "cgi"

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
    # Consensus estimates and beta live behind the quote-summary endpoint, which
    # wants a session cookie and a matching "crumb" (an anti-forgery token the
    # site hands out once the cookie is set). The three-step dance below is the
    # public one every browser does; neither the cookie nor the crumb is cached.
    COOKIE_URL = "https://fc.yahoo.com"
    CRUMB_URL = "https://query2.finance.yahoo.com/v1/test/getcrumb"
    ESTIMATES_URL = "https://query2.finance.yahoo.com/v10/finance/quoteSummary/%<ticker>s?modules=earningsTrend,defaultKeyStatistics"
    ESTIMATE_PERIODS = %w[0y +1y].freeze

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
        share_price: py_round(price, 2),
        currency: meta.fetch(:currency, "USD"),
        week52_low: truthy(low) ? py_round(low, 2) : nil,
        week52_high: truthy(high) ? py_round(high, 2) : nil,
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

    # Consensus revenue and EPS for the fiscal year in progress and the next,
    # plus beta: {ticker:, estimates: [{fiscal_year:, period_end:, revenue:,
    # eps:, analysts:, source:}], beta:, as_of:} or nil. Revenue in millions,
    # like the rest of the application. Cached per (ticker, calendar day) as
    # the parsed payload, never the session cookie or crumb.
    def fetch_estimates(ticker, cache: true, on: Date.today)
      path = Http.cache_path("estimates://#{ticker.upcase}?asof=#{on.iso8601}")
      payload =
        if cache && path.exist?
          JSON.parse(File.read(path), symbolize_names: true)
        else
          fetched = estimates_payload(ticker)
          if fetched && cache
            Http.cache_dir.mkpath
            File.binwrite(path, JSON.generate(fetched))
          end
          fetched
        end
      payload && parse_estimates(payload, ticker: ticker, on: on)
    rescue StandardError
      nil
    end

    # The network seam (tests replace it): cookie, crumb, then the summary.
    def estimates_payload(ticker)
      headers = { "User-Agent" => QUOTE_USER_AGENT, "Accept" => "*/*" }
      cookie = Http.perform_request(URI.parse(COOKIE_URL), headers, 20).get_fields("set-cookie").to_a
                   .map { |line| line.split(";", 2).first }.join("; ")
      return nil if cookie.empty?

      headers["Cookie"] = cookie
      crumb = Http.perform_request(URI.parse(CRUMB_URL), headers, 20).body.to_s.strip
      return nil if crumb.empty? || crumb.include?("<")

      url = "#{format(ESTIMATES_URL, ticker: ticker.upcase)}&crumb=#{CGI.escape(crumb)}"
      response = Http.perform_request(URI.parse(url), headers, 20)
      return nil unless response.code.to_i == 200

      JSON.parse(response.body.to_s, symbolize_names: true)
    end

    def parse_estimates(payload, ticker:, on: Date.today)
      result = (payload.dig(:quoteSummary, :result) || []).first
      return nil if result.nil?

      rows = (result.dig(:earningsTrend, :trend) || []).filter_map do |trend|
        next unless ESTIMATE_PERIODS.include?(trend[:period].to_s)

        end_date = trend[:endDate].to_s
        next if end_date.empty?

        revenue = trend.dig(:revenueEstimate, :avg, :raw)
        eps = trend.dig(:earningsEstimate, :avg, :raw)
        next if revenue.nil? && eps.nil?

        analysts = trend.dig(:revenueEstimate, :numberOfAnalysts, :raw) || trend.dig(:earningsEstimate, :numberOfAnalysts, :raw)
        {
          fiscal_year: Sec.fiscal_year(end_date),
          period_end: Date.iso8601(end_date),
          revenue: revenue.nil? ? nil : py_round(revenue.to_f / 1e6, 1),
          eps: eps.nil? ? nil : py_round(eps.to_f, 2),
          analysts: analysts&.to_i,
          source: "consensus (Yahoo Finance, #{analysts.to_i} analysts)"
        }
      end
      beta = result.dig(:defaultKeyStatistics, :beta, :raw)
      { ticker: ticker.upcase, estimates: rows.sort_by { |row| row[:period_end] }, beta: beta&.to_f, as_of: on }
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

    # Python's round(): the exact binary value, half-to-even (80.125 -> 80.12,
    # where Float#round says 80.13). Same rule as Sec.py_round; a quote is a
    # stored figure too, so it must match the reference loader.
    def py_round(value, digits)
      float = value.to_f
      return float unless float.finite?

      scale = 10**digits
      Rational((float.to_r * scale).round(half: :even), scale).to_f
    end
  end
end
