# frozen_string_literal: true

module Pitchbooks
  module Slides
    # Historical and projected financials by fiscal year.
    #
    # The series is fiscal years only: an LTM row shares its fiscal_year with the
    # year it extends and would print twice on the axis, so it travels
    # separately (payload `ltm`). A missing figure stays nil (rendered "n/a"),
    # where the reference turned it into 0.
    module FinancialPerformance
      F = Format
      FIELDS = %i[ebitda ebit net_income eps capex dep_amort].freeze

      module_function

      def build(ctx)
        m = ctx.metrics
        financials = Array(m[:financials])
        rows = financials.reject { |row| row[:period_type] == "LTM" }.map { |row| row_for(row) }
        ltm_source = financials.select { |row| row[:period_type] == "LTM" }.max_by { |row| row[:period_end].to_s }

        growths = (1...rows.size).filter_map do |i|
          prior = rows[i - 1][:revenue]
          current = rows[i][:revenue]
          (current / prior - 1).round(4) if F.present_number?(prior) && !current.nil?
        end
        cagr = nil
        if rows.size >= 2 && F.present_number?(rows.first[:revenue]) && F.present_number?(rows.last[:revenue])
          periods = rows.last[:fiscal_year].to_i - rows.first[:fiscal_year].to_i
          cagr = ((rows.last[:revenue] / rows.first[:revenue])**(1.0 / periods) - 1).round(4) if periods.positive?
        end

        {
          title: "#{m[:name]} — financial performance",
          subtitle: "#{ctx.currency}m, fiscal years; forward years are estimates",
          payload: {
            rows: rows,
            growths: growths,
            revenue_cagr: cagr,
            currency: ctx.currency,
            ltm: ltm_source && row_for(ltm_source).merge(basis: Valuation.basis_label(ltm_source)),
            note: note(rows, cagr)
          }
        }
      end

      def row_for(row)
        revenue = F.float_or_nil(row[:revenue])
        ebitda = F.float_or_nil(row[:ebitda])
        out = {
          fiscal_year: row[:fiscal_year],
          period_type: row[:period_type] || "FY",
          is_estimate: row[:is_estimate] ? true : false,
          estimate_source: row[:estimate_source],
          revenue: revenue,
          ebitda: ebitda,
          ebitda_margin: F.present_number?(revenue) && !ebitda.nil? ? (ebitda / revenue).round(4) : nil
        }
        FIELDS.each { |key| out[key] ||= F.float_or_nil(row[key]) }
        out
      end

      # One data-driven sentence; empty when the figures for it are missing.
      def note(rows, cagr)
        return "" if cagr.nil? || rows.empty?

        first = rows.first
        last = rows.last
        estimates = rows.select { |r| r[:is_estimate] }
        span = "FY#{first[:fiscal_year]}–FY#{last[:fiscal_year]}"
        span += " (FY#{estimates.first[:fiscal_year]} onward estimated)" if estimates.any?
        text = +"Revenue compounds at #{F.pct(cagr)} a year across #{span}"
        if first[:ebitda_margin] && last[:ebitda_margin]
          text << " with EBITDA margin moving from #{F.pct(first[:ebitda_margin])} to #{F.pct(last[:ebitda_margin])}"
        end
        "#{text}."
      end
    end
  end
end
