# frozen_string_literal: true

# Company list and company pages: research and financials side by side, and
# the button that turns a company into a pitch book.
#
# Port of loadCompanies/renderCompany in argos/static/app.js and the
# get_companies / get_company / get_company_charts handlers in argos/api.py.
# The October 2026 audit (docs/RAILS_PORT.md items 11–17 and 20) adds what the
# page must now say beside each number: the period every multiple is quoted
# on, the EV bridge with its balance-sheet date and form, which share count
# the per-share figures rest on, NTM multiples (and whether the EBITDA was
# derived), and whether a KPI tile is company-level.
class CompaniesController < ApplicationController
  helper DashboardController::Formatting

  def index
    @companies = company_rows
  end

  def show
    @companies = company_rows
    @profile = Analytics.company_profile(params[:ticker])
    unless @profile
      return render("shared/not_found", status: :not_found, locals: { what: "Company #{params[:ticker].to_s.upcase}" })
    end

    @metrics = @profile[:metrics] || {}
    @market = @profile[:market_data] || {}
    @currency = @metrics[:currency] || @profile[:currency].presence || "USD"
    @share_basis = share_basis(@market)
    build_charts
  end

  # Generate a deck on this company and open it.
  def pitchbook
    company = Company.find_ticker(params[:ticker])
    return redirect_to(companies_path, alert: "Unknown company #{params[:ticker]}", status: :see_other) unless company

    title = params[:title].presence || "Project #{company.name.split.first}"
    book = Pitchbooks.create!(title: title, target_ticker: company.ticker)
    redirect_to pitchbook_path(book), notice: "Deck generated: #{book.title}", status: :see_other
  rescue ArgumentError, ActiveRecord::RecordInvalid, ActiveRecord::RecordNotFound => e
    redirect_to company_path(params[:ticker]), alert: "Could not generate a deck: #{e.message}", status: :see_other
  end

  private

  # The sidebar list: the reference's get_companies query.
  def company_rows
    ActiveRecord::Base.connection.select_all(<<~SQL).to_a.map(&:symbolize_keys)
      SELECT c.id, c.ticker, c.name, c.sector, c.industry, c.country, c.hq, c.employees, c.currency,
             m.share_price, m.shares_diluted, m.net_debt, m.as_of,
             (SELECT COUNT(*) FROM documents d WHERE d.company_id = c.id) AS documents,
             (SELECT ROUND(AVG(d.sentiment), 3) FROM documents d WHERE d.company_id = c.id) AS sentiment
      FROM companies c LEFT JOIN market_data m ON m.company_id = c.id
      ORDER BY c.ticker
    SQL
  end

  # Which share count the per-share figures use (contract items 2 and 17).
  # The loader stores the diluted weighted average in shares_diluted and the
  # cover-page count in shares_basic; when they differ the diluted count was
  # used, otherwise the cover-page count stands in (no diluted figure, or it
  # failed the latest-year / 0.5–2x guards).
  def share_basis(market)
    diluted = market[:shares_diluted]
    basic = market[:shares_basic]
    return { label: "n/a", detail: "No share count loaded." } if diluted.nil?

    if !basic.nil? && (basic.to_f - diluted.to_f).abs > 1e-9
      { label: "Diluted weighted-average shares",
        detail: "Per-share figures use the diluted weighted-average count (latest fiscal year), " \
                "not the cover-page count of #{helpers.num(basic, 2)}m." }
    else
      { label: "Cover-page share count",
        detail: "Per-share figures use the cover-page share count; no diluted weighted-average count was used." }
    end
  end

  # The four company charts, as get_company_charts drew them.
  #
  # Only fiscal-year rows are plotted: an LTM row shares its fiscal year with
  # the year it extends and would be a second bar under the same label. A
  # year with no revenue is left out rather than drawn as a zero bar.
  def build_charts
    fiscal = (@profile[:financials] || []).reject { |row| row[:period_type] == "LTM" }
    plotted = fiscal.reject { |row| row[:revenue].nil? }
    labels = plotted.map { |row| "FY#{row[:fiscal_year]}#{'E' if row[:is_estimate]}" }
    estimate_from = plotted.index { |row| row[:is_estimate] }
    margins = plotted.map do |row|
      revenue = row[:revenue].to_f
      row[:ebitda].nil? || revenue.zero? ? nil : row[:ebitda].to_f / revenue * 100
    end
    timeline = @profile[:sentiment_timeline] || []
    volume = Analytics.volume_by_type(ticker: @profile[:ticker])
    @charts = {
      revenue: Charts.column_chart_svg(labels, plotted.map { |row| row[:revenue].to_f },
                                       title: "Revenue (#{@currency}m)", estimate_from: estimate_from),
      margin: Charts.line_chart_svg(labels, margins, title: "EBITDA margin (%)"),
      sentiment: Charts.diverging_bar_svg(timeline.map { |row| row[:month].to_s[-5..] },
                                          timeline.map { |row| row[:sentiment].to_f },
                                          title: "Document tone by month (−1 to +1)"),
      volume: Charts.stacked_bar_svg(volume[:months].map { |month| month.to_s[-5..] }, volume[:series],
                                     title: "Documents published by type")
    }
  end
end
