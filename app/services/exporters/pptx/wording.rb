# frozen_string_literal: true

module Exporters
  module Pptx
    # The sentences and label/value rows that both file exporters print for the
    # payload keys added by the audit (RAILS_PORT.md items 16-18 and 22): the
    # cover stamp, the implied-value line, the comps footnotes, the valuation
    # conclusion, the DCF bridge and WACC build, and the sensitivity note.
    #
    # It lives here because the PPTX writer was its first user; Exporters::Pdf
    # calls the same functions so a deck says the same thing in every format,
    # and the HTML partials (decks/slides/*) use the same wording. Every nil
    # prints as "n/a" (or "not bridged" where the missing figure is a bridge
    # through unknown net debt), never as $0.00: an audit found the exports
    # printing "Reference range $0.00 – $0.00" on a deck whose net debt was
    # not loaded.
    module Wording
      NA = "n/a"
      CURRENCY_SYMBOLS = { "USD" => "$", "EUR" => "€", "GBP" => "£" }.freeze

      module_function

      # ------------------------------------------------------------ primitives

      def symbol(currency) = CURRENCY_SYMBOLS.fetch((currency.presence || "USD").to_s.upcase, "")

      def number?(value)
        !value.nil? && !value.is_a?(String) && Float(value).finite?
      rescue ArgumentError, TypeError
        false
      end

      # Dates arrive as Date (a fresh build) or ISO strings (read back from JSON).
      def date(value)
        return NA if value.blank?
        return value.to_date.iso8601 if value.respond_to?(:to_date) && !value.is_a?(String)

        value.to_s[0, 10]
      end

      def price(value, currency = "USD")
        number?(value) ? "#{symbol(currency)}#{Charts.number(value, decimals: 2)}" : NA
      end

      # Millions with an "m" suffix, as the DCF bridge prints ("$1,061m").
      def money(value, currency = "USD", decimals: 0)
        number?(value) ? "#{symbol(currency)}#{Charts.number(value, decimals: decimals)}m" : NA
      end

      def pct(value, digits = 1)
        number?(value) ? "#{Charts.fixed(Float(value) * 100, decimals: digits)}%" : NA
      end

      def mult(value, digits = 1)
        number?(value) ? "#{Charts.fixed(value, decimals: digits)}x" : NA
      end

      def decimal(value, digits = 2)
        number?(value) ? Charts.fixed(value, decimals: digits) : NA
      end

      # ----------------------------------------------------------------- cover

      # Item 22: which data and which code produced the deck. nil without a stamp
      # (decks built before the stamp existed, fixtures).
      def stamp_line(stamp)
        return nil if stamp.blank?

        built = stamp[:built_on].presence || stamp[:built_at]
        "Data as of #{date(stamp[:data_as_of])} · prices as of #{date(stamp[:price_date])} · " \
          "built #{date(built)} · code #{stamp[:code_version].presence || 'unknown'}"
      end

      # ------------------------------------------------- summary / process line

      # Item 16: the concluded range is "implied value at peer multiples and
      # DCF", stated against the price without calling the gap a move. When net
      # debt is unknown nothing bridges to a per-share value, and the line says so.
      def implied_value_line(payload)
        reference = payload[:reference_range] || {}
        currency = payload[:currency]
        range =
          if number?(reference[:low]) && number?(reference[:high])
            "Implied value at peer multiples and DCF #{price(reference[:low], currency)} – " \
              "#{price(reference[:high], currency)} per share"
          else
            "Implied value at peer multiples and DCF: not bridged to a per-share value"
          end
        current = "current #{price(payload[:share_price], currency)}"
        current += " as of #{date(payload[:price_date])}" if payload[:price_date].present?
        basis = payload[:basis_label].present? ? "  ·  multiples on #{payload[:basis_label]}" : ""
        "#{range}  ·  #{current}#{basis}"
      end

      # -------------------------------------------------------- company overview

      def overview_footnote(payload)
        keys = %i[basis_label price_date balance_sheet_date debt_note]
        return nil unless keys.any? { |key| payload.key?(key) }

        text = +"Multiples on #{payload[:basis_label].presence || NA}; price as of #{date(payload[:price_date])}; " \
                "balance sheet as of #{date(payload[:balance_sheet_date])}."
        text << " #{payload[:debt_note]}" if payload[:debt_note].present?
        text
      end

      # ----------------------------------------------------------- trading comps

      # Item 17: price date, balance-sheet date, the basis of the target's
      # multiples, the share-count basis, the derived-NTM flag and the EBITDA
      # definition. Empty for a payload that carries none of them.
      def comps_footnotes(payload)
        keys = %i[price_date balance_sheet_date basis_label share_count_basis footnote]
        return [] unless keys.any? { |key| payload.key?(key) }

        dates = +"Prices as of #{date(payload[:price_date])}; balance sheets as of #{date(payload[:balance_sheet_date])}; " \
                 "target multiples on #{payload[:basis_label].presence || NA}."
        dates << " #{payload[:share_count_basis]}" if payload[:share_count_basis].present?
        notes = [dates]
        if payload[:ntm_derived]
          notes << "NTM EBITDA marked derived is consensus revenue at the current margin: no public source publishes consensus EBITDA."
        end
        notes << payload[:footnote].to_s if payload[:footnote].present?
        notes
      end

      # Comps columns beyond the Python set, present only when the payload
      # carries them (a deck built before the audit has none of these keys).
      def comps_rows(payload)
        target = payload[:target].presence
        (target ? [target] : []) + Array(payload[:rows])
      end

      def comps_basis?(payload) = comps_rows(payload).any? { |row| row.key?(:basis) }
      def comps_share_basis?(payload) = comps_rows(payload).any? { |row| row.key?(:share_basis) }

      # Rows marked derived get a dagger on their NTM multiple, the PPTX/PDF
      # equivalent of the HTML footnote marker.
      def ntm_cell(row, key)
        value = row[key]
        return nil if value.nil?

        text = "#{Charts.fixed(value, decimals: 1)}x"
        key == :ev_ebitda_ntm && row[:ntm_ebitda_derived] ? "#{text}†" : text
      end

      # -------------------------------------------------------- valuation summary

      # A range that does not set the conclusion: the 52-week range (reference
      # only) or a method excluded with a note (item 14). Drawn muted.
      def muted_range?(range) = range[:reference] ? true : range[:in_conclusion] == false

      def range_status(range)
        return "reference only" if range[:reference]
        return "excluded" if range[:in_conclusion] == false

        nil
      end

      def status_label(range)
        return "Reference only" if range[:reference]
        return "Excluded" if range[:in_conclusion] == false

        "Yes"
      end

      def flagged_ranges?(ranges) = Array(ranges).any? { |r| r.key?(:in_conclusion) || r.key?(:reference) }

      # A bar needs both ends; a method whose range could not be computed stays
      # in the table (as n/a) but not on the chart.
      def drawable_ranges(ranges) = Array(ranges).select { |r| number?(r[:low]) && number?(r[:high]) }

      # The concluded range with the methods that set it (item 16 wording).
      def conclusion_sentence(payload)
        concluded = payload[:concluded_range] || {}
        currency = payload[:currency]
        ranges = Array(payload[:ranges])
        unless number?(concluded[:low]) && number?(concluded[:high])
          text = +"The methods could not be bridged to a per-share value, so no concluded range is stated."
          text << " #{payload[:dcf_note]}" if payload[:dcf_note].present?
          return text
        end

        methods = Array(payload[:methods].presence || concluded[:methods])
        text = +"Implied value at peer multiples and DCF of #{price(concluded[:low], currency)}–#{price(concluded[:high], currency)} per share"
        text << if methods.any?
                  ": the median low and median high of the #{methods.size} #{methods.size == 1 ? 'method' : 'methods'} " \
                    "in the conclusion (#{methods.join(', ')})."
                else
                  "."
                end
        text << " The 52-week range is shown for reference only." if ranges.any? { |r| r[:reference] }
        if number?(payload[:reference_price])
          text << " Current price #{price(payload[:reference_price], currency)}"
          text << " as of #{date(payload[:price_date])}" if payload[:price_date].present?
          text << "."
        end
        text
      end

      # "method: note" for each range that carries one (why EV/Revenue is excluded).
      def range_notes(ranges) = Array(ranges).select { |r| r[:note].present? }.map { |r| "#{r[:method]}: #{r[:note]}" }

      # ---------------------------------------------------------------------- DCF

      def extended_dcf?(payload)
        %i[wacc_build terminal_year stub_fraction valuation_date implied_exit_multiple implied_terminal_growth]
          .any? { |key| payload.key?(key) } ||
          Array(payload[:projections]).any? { |p| p.key?(:dep_amort) || p.key?(:nwc_change) }
      end

      # The EV-to-share bridge with the cross-checks. Equity value and value per
      # share are nil when net debt is unknown: that is "not bridged", not zero.
      def dcf_bridge_rows(payload)
        currency = payload[:currency]
        bridged = ->(value, text) { value.nil? ? "not bridged" : text }
        rows = [
          ["PV of forecast FCF", money(payload[:pv_explicit], currency)],
          ["PV of terminal value", money(payload[:pv_terminal], currency)],
          ["Enterprise value", money(payload[:enterprise_value], currency)],
          ["Equity value", bridged.(payload[:equity_value], money(payload[:equity_value], currency))],
          ["Value per share", bridged.(payload[:value_per_share], price(payload[:value_per_share], currency))],
          ["Current share price", price(payload[:share_price], currency)]
        ]
        rows << ["Implied exit multiple", mult(payload[:implied_exit_multiple])] if payload.key?(:implied_exit_multiple)
        rows << ["Implied terminal growth", pct(payload[:implied_terminal_growth])] if payload.key?(:implied_terminal_growth)
        if payload.key?(:stub_fraction) || payload.key?(:valuation_date)
          rows << ["Stub fraction · valuation date", "#{decimal(payload[:stub_fraction])} · #{date(payload[:valuation_date])}"]
        end
        rows
      end

      # Item 18: the inputs of the built-up WACC, saying when beta was assumed.
      def wacc_rows(build)
        return [] if build.blank?

        [
          ["Risk-free rate", pct(build[:risk_free_rate], 2)],
          ["Beta#{' (assumed — not loaded)' if build[:beta_assumed]}", decimal(build[:beta])],
          ["Equity risk premium", pct(build[:equity_risk_premium], 2)],
          ["Cost of equity", pct(build[:cost_of_equity], 2)],
          ["Pre-tax cost of debt", pct(build[:pre_tax_cost_of_debt], 2)],
          ["Tax rate", pct(build[:tax_rate], 1)],
          ["After-tax cost of debt", pct(build[:after_tax_cost_of_debt], 2)],
          ["Debt / equity weights", "#{pct(build[:weight_debt])} / #{pct(build[:weight_equity])}"],
          ["WACC (built)", pct(build[:wacc], 2)]
        ]
      end

      # The terminal year as a projections-table row: the label in the year
      # column, its own figures, and the PV of the terminal value in the PV
      # column. A floored capex carries an asterisk explained in the notes.
      def terminal_row(payload)
        terminal = payload[:terminal_year]
        return nil if terminal.blank?

        capex = terminal[:capex]
        capex = "#{Charts.number(capex, decimals: 0)}*" if terminal[:capex_floored_at_da] && number?(capex)
        # The stub columns do not apply to the terminal year: a dash, as in the
        # HTML table, rather than "n/a" (which would read as a missing figure).
        terminal.slice(:revenue, :growth, :ebitda, :ebitda_margin, :dep_amort, :ebit, :taxes, :nwc_change).merge(
          year: "Terminal (#{terminal[:year] || NA})", capex: capex, fcf: terminal[:fcf], fcf_full_year: terminal[:fcf],
          period_fraction: "—", fcf_counted: "—", pv_fcf: payload[:pv_terminal], is_terminal: true
        )
      end

      # Every sentence under the DCF tables, in reading order and without repeats:
      # the value sentence, the stub/WACC/cross-check notes, the WACC build's own
      # notes, the bridge note and the terminal value.
      def dcf_notes(payload)
        currency = payload[:currency]
        out = [payload[:note]]
        out.concat(Array(payload[:notes]))
        out.concat(Array(payload.dig(:wacc_build, :notes)))
        out << payload[:bridge_note]
        if payload.key?(:terminal_value)
          out << "Terminal value #{money(payload[:terminal_value], currency)}" \
                 "#{payload[:terminal_method].present? ? " (#{payload[:terminal_method]})" : ''}, " \
                 "present value #{money(payload[:pv_terminal], currency)}."
        end
        texts = out.compact.map(&:to_s).map(&:strip).reject(&:empty?)
        # The value sentence already quotes the bridge note when equity is unknown.
        texts.each_with_index.reject { |text, index| texts[0...index].any? { |earlier| earlier.include?(text) } }.map(&:first)
      end

      # The projections-table columns: the Python set, plus D&A and ΔNWC when
      # the payload carries them so UFCF ties (EBIT − taxes + D&A − capex − ΔNWC),
      # plus the stub fraction and the counted cash flow when a stub applies.
      def dcf_columns(payload)
        projections = Array(payload[:projections])
        da = projections.any? { |p| p.key?(:dep_amort) }
        nwc = projections.any? { |p| p.key?(:nwc_change) }
        stub = projections.any? { |p| number?(p[:period_fraction]) && (Float(p[:period_fraction]) - 1).abs > 1e-9 }
        full_year = projections.any? { |p| p.key?(:fcf_full_year) }
        columns = [
          { key: :year, label: "Year", format: "{:.0f}" },
          { key: :revenue, label: "Revenue", numeric: true, format: "{:,.0f}" },
          { key: :growth, label: "Growth", numeric: true, format: "{:.1%}" },
          { key: :ebitda, label: "EBITDA", numeric: true, format: "{:,.0f}" }
        ]
        columns << { key: :dep_amort, label: "D&A", numeric: true, format: "{:,.0f}" } if da
        columns += [
          { key: :ebit, label: "EBIT", numeric: true, format: "{:,.0f}" },
          { key: :taxes, label: "Taxes", numeric: true, format: "{:,.0f}" },
          { key: :capex, label: "Capex", numeric: true, format: "{:,.0f}" }
        ]
        columns << { key: :nwc_change, label: "ΔNWC", numeric: true, format: "{:,.0f}" } if nwc
        columns << { key: full_year ? :fcf_full_year : :fcf, label: "UFCF", numeric: true, format: "{:,.0f}" }
        if stub
          columns << { key: :period_fraction, label: "Fraction", numeric: true, format: "{:.2f}" }
          columns << { key: :fcf_counted, label: "Counted", numeric: true, format: "{:,.0f}" }
        end
        columns << { key: :pv_fcf, label: "PV", numeric: true, format: "{:,.0f}" }
        columns
      end

      def dcf_table_rows(payload)
        rows = Array(payload[:projections]).map { |p| p.merge(fcf_counted: p[:fcf]) }
        terminal = terminal_row(payload)
        rows << terminal if terminal
        rows
      end

      # ------------------------------------------------------------ sensitivity

      def sensitivity_note(payload)
        currency = payload[:currency].presence || "USD"
        price_text = number?(payload[:reference_price]) ? "#{price(payload[:reference_price], currency)}." : "not loaded."
        text = +"Value per share (#{currency}); current share price #{price_text}"
        text << " #{payload[:bridge_note]}" if payload[:bridge_note].present?
        text
      end
    end
  end
end
