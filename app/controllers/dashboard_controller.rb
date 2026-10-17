# frozen_string_literal: true

# Landing page: corpus coverage, tone and what is emerging.
#
# Port of loadDashboard() in argos/static/app.js, which fetched /api/overview
# and /api/dashboard-charts and laid them out in the browser. Here the same two
# calls happen on the server and the charts are the Charts SVG strings, so the
# figures on screen and in the exported deck come from one implementation.
class DashboardController < ApplicationController
  # Number formats shared by every page of the research UI.
  #
  # Each is the Ruby twin of a formatter in app.js (money, price, pct, mult,
  # num, sentimentPill) with one rule throughout: nil is unknown and renders
  # "n/a", never 0. Kept here, beside the first controller that needs it,
  # because the porting split gives this module no helper file of its own;
  # the other research controllers include it with `helper`.
  module Formatting
    CURRENCY_SYMBOLS = { "USD" => "$", "EUR" => "€", "GBP" => "£" }.freeze
    NA = "n/a"

    def currency_symbol(currency)
      CURRENCY_SYMBOLS.fetch(currency.to_s.presence || "USD", "")
    end

    # Millions in, "$1.2bn" / "$345m" out (app.js `money`).
    def money(value, currency = "USD")
      return NA if value.nil?

      amount = value.to_f
      symbol = currency_symbol(currency)
      if amount.abs >= 1000
        "#{symbol}#{num(amount / 1000, 1)}bn"
      else
        "#{symbol}#{num(amount, 0)}m"
      end
    end

    # A per-share price with two decimals (app.js `price`).
    def price(value, currency = "USD")
      return NA if value.nil?

      "#{currency_symbol(currency)}#{Charts.fixed(value.to_f, decimals: 2)}"
    end

    # A decimal rate as a percentage: 0.231 -> "23.1%" (app.js `pct`).
    def pct(value, digits = 1)
      return NA if value.nil?

      "#{Charts.fixed(value.to_f * 100, decimals: digits)}%"
    end

    # A valuation multiple: 12.34 -> "12.3x" (app.js `mult`).
    def mult(value)
      return NA if value.nil?

      "#{Charts.fixed(value.to_f, decimals: 1)}x"
    end

    # Grouped number with at most `digits` decimals, trailing zeros dropped —
    # what toLocaleString(undefined, {maximumFractionDigits}) printed.
    def num(value, digits = 0)
      return NA if value.nil?

      text = Charts.number(value.to_f, decimals: digits)
      text = text.sub(/\.?0+\z/, "") if digits.positive? && text.include?(".")
      text
    end

    # Signed tone, "+0.12" / "-0.30".
    def tone(value)
      return NA if value.nil?

      Charts.fixed(value.to_f, decimals: 2, sign: true)
    end

    # ISO date text, or n/a.
    def iso(value)
      value.nil? || value.to_s.empty? ? NA : value.to_s[0, 10]
    end

    # Tone pill: coloured when the score clears the ±0.18 thresholds.
    # The reference labelled a zero score "positive" when no label came with
    # it; the label now always comes from Nlp's thresholds.
    def sentiment_pill(score, label = nil)
      return tag.span("tone n/a", class: "pill", title: "Document tone") if score.nil?

      value = score.to_f
      tone_class = if value >= 0.18 then "pos" elsif value <= -0.18 then "neg" end
      tag.span("#{label.presence || Nlp.sentiment_label(value)} #{tone(value)}",
               class: ["pill", tone_class].compact.join(" "), title: "Document tone")
    end

    # Display name for a KPI metric key ("net_retention" -> "Net dollar retention").
    def metric_label(metric)
      Analytics::KPI_LABELS.fetch(metric.to_s) { metric.to_s.tr("_", " ") }
    end

    # A KPI value with its unit, as the reference printed it.
    def kpi_value(value, unit)
      return NA if value.nil?

      "#{num(value, 1)}#{'%' if unit == '%'}"
    end
  end

  helper Formatting

  def index
    @overview = Analytics.overview
    months = params.fetch(:months, 24).to_i
    months = 24 unless months.positive?
    timeline = Analytics.sentiment_timeline(months: months)
    volume = Analytics.volume_by_type(months: months)
    # Month labels are cut to "YY-MM" as the reference did, so 24 fit the axis.
    @sentiment_svg = Charts.diverging_bar_svg(
      timeline.map { |row| row[:month].to_s[-5..] },
      timeline.map { |row| row[:sentiment].to_f },
      title: "Corpus tone by month (−1 to +1)"
    )
    @volume_svg = Charts.stacked_bar_svg(
      volume[:months].map { |month| month.to_s[-5..] }, volume[:series],
      title: "Documents published by type"
    )
    distribution = (@overview.dig(:sentiment, :distribution) || []).to_h { |row| [row[:value], row[:count]] }
    @positive = distribution.fetch("positive", 0)
    @negative = distribution.fetch("negative", 0)
  end
end
