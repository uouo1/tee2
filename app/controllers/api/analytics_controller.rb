# frozen_string_literal: true

module Api
  # Corpus-level analytics: get_overview, get_trends and get_dashboard_charts
  # in argos/api.py.
  class AnalyticsController < BaseController
    def overview
      render json: Analytics.overview
    end

    def trends
      ticker = first(:ticker).presence
      months = int_param(:months, 24)
      render json: {
        themes: Analytics.trending_themes(window_days: int_param(:window_days, 120), ticker: ticker,
                                          limit: int_param(:limit, 12)),
        sentiment_timeline: Analytics.sentiment_timeline(ticker: ticker, months: months),
        volume_by_type: Analytics.volume_by_type(ticker: ticker, months: months)
      }
    end

    # Server-rendered SVG for the dashboard. Rendering on the server means the
    # figures on screen and in an exported deck come from one implementation.
    def dashboard_charts
      months = int_param(:months, 24)
      timeline = Analytics.sentiment_timeline(months: months)
      volume = Analytics.volume_by_type(months: months)
      render json: {
        # Month labels are cut to "YY-MM" so 24 of them fit the axis. The chart
        # needs a number per bar; a month whose documents carry no tone at all
        # sits on the zero line, as in the reference.
        sentiment: Charts.diverging_bar_svg(
          timeline.map { |row| row[:month].to_s[-5..] },
          timeline.map { |row| row[:sentiment].to_f },
          title: "Corpus tone by month (−1 to +1)"
        ),
        volume: Charts.stacked_bar_svg(
          volume[:months].map { |month| month.to_s[-5..] }, volume[:series],
          title: "Documents published by type"
        )
      }
    end
  end
end
