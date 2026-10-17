# frozen_string_literal: true

module Api
  # Companies: the list, one profile, its charts and suggested comparables
  # (get_companies, get_company, get_company_charts and get_suggest_comps in
  # argos/api.py).
  class CompaniesController < BaseController
    # The reference's query plus the columns the audit made part of every
    # number's provenance (docs/RAILS_PORT.md item 17): the price date, the
    # balance-sheet date and the cover-page share count beside the diluted one.
    # A company with no market data or no documents reports null, never 0.
    COMPANIES_SQL = <<~SQL
      SELECT c.id, c.ticker, c.name, c.sector, c.industry, c.country, c.hq, c.employees, c.currency,
             m.share_price, m.shares_diluted, m.shares_basic, m.net_debt, m.net_debt_as_of, m.as_of,
             (SELECT COUNT(*) FROM documents d WHERE d.company_id = c.id) AS documents,
             (SELECT ROUND(AVG(d.sentiment), 3) FROM documents d WHERE d.company_id = c.id) AS sentiment
      FROM companies c LEFT JOIN market_data m ON m.company_id = c.id
      ORDER BY c.ticker
    SQL

    def index
      render json: { companies: ActiveRecord::Base.connection.select_all(COMPANIES_SQL).to_a }
    end

    # The profile carries Valuation.company_metrics under "metrics" as it
    # stands: basis_label, ltm, ntm, ev_bridge and other_claims included.
    def show
      ticker = path_param(:ticker)
      profile = Analytics.company_profile(ticker)
      raise Error.new("company #{ticker} not found", 404) unless profile

      profile[:volume_by_type] = Analytics.volume_by_type(ticker: profile[:ticker])
      render json: profile
    end

    # Server-rendered SVG for a company page.
    #
    # Rendering charts in Ruby rather than in the browser means the figures on
    # screen and the figures in the exported deck come from one implementation.
    #
    # Only fiscal-year rows are plotted: an LTM row shares its fiscal year with
    # the year it extends and would be a second bar under the same label. A
    # year with no revenue is left out rather than drawn as a zero bar, and a
    # margin that cannot be computed is a gap in the line, not 0%.
    def charts
      ticker = path_param(:ticker)
      profile = Analytics.company_profile(ticker)
      raise Error.new("company #{ticker} not found", 404) unless profile

      financials = (profile[:financials] || []).reject { |row| row[:period_type] == "LTM" || row[:revenue].nil? }
      labels = financials.map { |row| "FY#{row[:fiscal_year]}" }
      estimate_from = financials.index { |row| row[:is_estimate] }
      margins = financials.map do |row|
        revenue = row[:revenue].to_f
        row[:ebitda].nil? || revenue.zero? ? nil : row[:ebitda].to_f / revenue * 100
      end
      timeline = profile[:sentiment_timeline] || []
      volume = Analytics.volume_by_type(ticker: profile[:ticker])
      currency = profile[:currency].presence || "USD"
      render json: {
        revenue: Charts.column_chart_svg(labels, financials.map { |row| row[:revenue].to_f },
                                         title: "Revenue (#{currency}m)", estimate_from: estimate_from),
        margin: Charts.line_chart_svg(labels, margins, title: "EBITDA margin (%)"),
        sentiment: Charts.diverging_bar_svg(timeline.map { |row| row[:month].to_s[-5..] },
                                            timeline.map { |row| row[:sentiment].to_f },
                                            title: "Document tone by month (−1 to +1)"),
        volume: Charts.stacked_bar_svg(volume[:months].map { |month| month.to_s[-5..] }, volume[:series],
                                       title: "Documents published by type")
      }
    end

    # Sector + size-ranked comparable suggestions for a target.
    def suggest_comps
      ticker = path_param(:ticker).upcase
      render json: { ticker: ticker, comps: Pitchbooks.suggest_comps(ticker) }
    end
  end
end
