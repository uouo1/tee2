# frozen_string_literal: true

module Pitchbooks
  module Slides
    # Number formatting shared by the slide builders (prose) and the deck
    # partials (tables, tiles). Port of the `_fmt_*` helpers in
    # argos/pitchbook.py and `_money/_pct/_mult` in argos/exporters/html_export.py.
    #
    # Every helper returns "n/a" for nil, which is right in a table cell or a
    # KPI tile and wrong in a sentence: prose builders check their inputs and
    # skip a sentence rather than print "n/a" inside it (RAILS_PORT.md item 19),
    # and `sentences` drops any that slipped through.
    module Format
      CURRENCY_SYMBOLS = { "USD" => "$", "EUR" => "€", "GBP" => "£" }.freeze
      NA = "n/a"

      # Chart/table cell formats: the Python format strings as Procs, the shape
      # Charts.table_html and Charts.column_chart_svg take.
      INT = Charts::INTEGER_FORMAT                                        # "{:,.0f}"
      DEC2 = Charts::DECIMAL_FORMAT                                       # "{:,.2f}"
      DEC3 = ->(v) { Charts.fixed(v, decimals: 3) }                       # "{:.3f}"
      PCT0 = ->(v) { "#{Charts.fixed(Float(v) * 100, decimals: 0)}%" }    # "{:.0%}"
      PCT1 = ->(v) { "#{Charts.fixed(Float(v) * 100, decimals: 1)}%" }    # "{:.1%}"
      MULT1 = ->(v) { "#{Charts.number(v, decimals: 1)}x" }               # "{:,.1f}x"
      MULT2 = ->(v) { "#{Charts.number(v, decimals: 2)}x" }               # "{:,.2f}x"
      FY = ->(v) { "FY#{v}" }                                             # "FY{}"
      PLAIN = ->(v) { v.to_s }

      module_function

      def symbol(currency)
        CURRENCY_SYMBOLS.fetch((currency.presence || "USD").to_s.upcase, "")
      end

      # Python truthiness for a figure: nil and zero are both "missing" (a zero
      # share price means no quote was loaded, not a free stock).
      def present_number?(value)
        figure = float_or_nil(value)
        !figure.nil? && !figure.zero?
      end

      def float_or_nil(value)
        return nil if value.nil?
        return value.to_f if value.is_a?(Numeric)

        Float(value, exception: false)
      end

      # $8.4bn / $410m, per the reference: millions in, bn above a thousand.
      def money(value, currency = "USD")
        amount = float_or_nil(value)
        return NA if amount.nil?

        sym = symbol(currency)
        return "#{sym}#{Charts.number(amount / 1000.0, decimals: 1)}bn" if amount.abs >= 1000

        "#{sym}#{Charts.number(amount)}m"
      end

      # Per-share figures keep their cents and never get bn/m scaling.
      def price(value, currency = "USD")
        amount = float_or_nil(value)
        return NA if amount.nil?

        "#{symbol(currency)}#{Charts.number(amount, decimals: 2)}"
      end

      def pct(value, digits = 1)
        rate = float_or_nil(value)
        return NA if rate.nil?

        "#{Charts.fixed(rate * 100, decimals: digits)}%"
      end

      def mult(value, digits = 1)
        figure = float_or_nil(value)
        return NA if figure.nil?

        "#{Charts.fixed(figure, decimals: digits)}x"
      end

      def count(value)
        figure = float_or_nil(value)
        figure.nil? ? NA : Charts.number(figure)
      end

      # Dates arrive as Date (fresh build) or ISO strings (read back from JSON).
      def date(value)
        return NA if value.blank?
        return value.iso8601 if value.respond_to?(:iso8601) && !value.is_a?(String)

        value.to_s[0, 10]
      end

      # "11.0x LTM Jun-26 EBITDA": every multiple names its period (item 17).
      def multiple_on(value, basis_label, metric)
        return nil if float_or_nil(value).nil?

        "#{mult(value)} #{basis_label} #{metric}".squeeze(" ")
      end

      # Drop sentences that are missing or that would print "n/a" mid-prose.
      def sentences(list)
        Array(list).compact.reject { |text| text.to_s.strip.empty? || na_inside?(text) }
      end

      def na_inside?(text)
        text.to_s.match?(%r{(?<![A-Za-z])n/a(?![A-Za-z])}i)
      end

      # Net debt / EBITDA in the four bands the audit asked for (item 19), as a
      # clause with its numbers; nil when net debt is unknown. `label` names
      # the EBITDA period.
      def leverage(net_debt, ebitda, label, currency = "USD")
        debt = float_or_nil(net_debt)
        return nil if debt.nil?

        earnings = float_or_nil(ebitda)
        if debt <= 0
          return "net cash of #{money(-debt, currency)}#{earnings&.positive? ? " against #{label} EBITDA of #{money(earnings, currency)}" : ''}"
        end
        return "net debt of #{money(debt, currency)} with no positive #{label} EBITDA to service it" unless earnings&.positive?

        ratio = debt / earnings
        band =
          if ratio < 1 then "below 1x"
          elsif ratio <= 3 then "between 1x and 3x"
          else "above 3x"
          end
        "net debt of #{money(debt, currency)} is #{mult(ratio)} #{label} EBITDA of #{money(earnings, currency)} (#{band})"
      end

      # The band alone, for comparisons: :net_cash, :below_1x, :one_to_three, :above_3x or nil.
      def leverage_band(net_debt, ebitda)
        debt = float_or_nil(net_debt)
        return nil if debt.nil?
        return :net_cash if debt <= 0

        earnings = float_or_nil(ebitda)
        return :above_3x unless earnings&.positive?

        ratio = debt / earnings
        if ratio < 1 then :below_1x
        elsif ratio <= 3 then :one_to_three
        else :above_3x
        end
      end

      def leverage_ratio(net_debt, ebitda)
        debt = float_or_nil(net_debt)
        earnings = float_or_nil(ebitda)
        return nil if debt.nil? || earnings.nil? || !earnings.positive?

        debt / earnings
      end
    end
  end
end
