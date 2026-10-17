# frozen_string_literal: true

module Sources
  # Monthly price history for the backtest.
  #
  # Yahoo's chart endpoint gives ten years of month bars with an adjusted close
  # (splits and dividends), which is what forward returns need. When it fails
  # after retries, Nasdaq's daily history is resampled to month ends; those bars
  # are unadjusted and are flagged so the report can count them.
  module PriceHistory
    # `events=splits` adds the split history the backtest needs to undo Yahoo's
    # split adjustment of the close (docs/BACKTEST.md, "Prices").
    YAHOO_URL = "https://query1.finance.yahoo.com/v8/finance/chart/%<ticker>s?range=10y&interval=1mo&events=splits&asof=%<month>s"
    NASDAQ_URL = "https://api.nasdaq.com/api/quote/%<ticker>s/historical?assetclass=stocks&fromdate=%<from>s&todate=%<to>s&limit=9999"
    BROWSER_USER_AGENT = Market::QUOTE_USER_AGENT

    module_function

    # [{month_end:, close:, adj_close:, source:, adjusted:}] oldest first, or [].
    def monthly_bars(ticker, cache: true, today: Date.today)
      history(ticker, cache: cache, today: today)[:bars]
    end

    # Bars plus the split history: {bars: [...], splits: [{date:, ratio:}]}.
    # The Nasdaq fallback carries no split events (its closes are unadjusted,
    # so none are needed to recover the raw close).
    def history(ticker, cache: true, today: Date.today)
      payload = yahoo_payload(ticker, cache: cache, today: today)
      bars = payload ? parse_yahoo(payload, today: today) : []
      return { bars: bars, splits: parse_splits(payload) } unless bars.empty?

      { bars: nasdaq_bars(ticker, cache: cache, today: today), splits: [] }
    end

    def yahoo_bars(ticker, cache: true, today: Date.today)
      payload = yahoo_payload(ticker, cache: cache, today: today)
      payload ? parse_yahoo(payload, today: today) : []
    end

    def yahoo_payload(ticker, cache: true, today: Date.today)
      url = format(YAHOO_URL, ticker: ticker.upcase, month: today.strftime("%Y-%m"))
      Http.fetch_json(url, cache: cache, user_agent: BROWSER_USER_AGENT)
    rescue Http::Error, JSON::ParserError
      nil
    end

    # Yahoo lists splits under events.splits keyed by timestamp, each with
    # numerator/denominator (a 4:1 split is 4/1). `ratio` is shares after per
    # share before, so a reverse split is below 1. Oldest first.
    def parse_splits(payload)
      result = (payload&.dig(:chart, :result) || []).first
      events = (result && result.dig(:events, :splits)) || {}
      events.values.filter_map do |event|
        numerator = event[:numerator].to_f
        denominator = event[:denominator].to_f
        next if numerator <= 0 || denominator <= 0 || event[:date].nil?

        { date: Time.at(Integer(event[:date])).utc.to_date, ratio: numerator / denominator }
      end.sort_by { |split| split[:date] }
    end

    # Yahoo stamps a month bar with the first trading day of its month; the bar
    # holds that month's close. An incomplete current month is dropped.
    def parse_yahoo(payload, today: Date.today)
      result = (payload.dig(:chart, :result) || []).first
      return [] unless result

      stamps = result[:timestamp] || []
      quote = (result.dig(:indicators, :quote) || []).first || {}
      adj = (result.dig(:indicators, :adjclose) || []).first || {}
      closes = quote[:close] || []
      adjusted = adj[:adjclose] || []
      bars = []
      stamps.each_with_index do |stamp, index|
        close = closes[index]
        next if close.nil?

        day = Time.at(Integer(stamp)).utc.to_date
        month_end = Date.new(day.year, day.month, -1)
        next if month_end > today # month still in progress

        bars << {
          month_end: month_end, close: close.to_f,
          adj_close: (adjusted[index] || close).to_f, source: "yahoo", adjusted: true
        }
      end
      bars.sort_by { |b| b[:month_end] }
    end

    def nasdaq_bars(ticker, cache: true, today: Date.today)
      url = format(NASDAQ_URL, ticker: ticker.upcase, from: (today << 120).iso8601, to: today.iso8601)
      payload = Http.fetch_json(url, cache: cache, user_agent: BROWSER_USER_AGENT)
      parse_nasdaq(payload, today: today)
    rescue Http::Error, JSON::ParserError
      []
    end

    # Daily rows ("10/12/2026", "$85.57") resampled to the last trading day of
    # each completed month. Unadjusted, and flagged as such.
    def parse_nasdaq(payload, today: Date.today)
      rows = payload.dig(:data, :tradesTable, :rows) || []
      by_month = {}
      rows.each do |row|
        day = Date.strptime(row[:date].to_s, "%m/%d/%Y")
        close = row[:close].to_s.delete("$,").to_f
        next if close <= 0

        key = Date.new(day.year, day.month, -1)
        next if key > today

        by_month[key] = [day, close] if by_month[key].nil? || day > by_month[key][0]
      end
      by_month.keys.sort.map do |month_end|
        { month_end: month_end, close: by_month[month_end][1], adj_close: by_month[month_end][1],
          source: "nasdaq", adjusted: false }
      end
    end
  end
end
