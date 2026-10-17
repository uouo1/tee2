# frozen_string_literal: true

module Pitchbooks
  module Slides
    # Discounted cash flow. Item 18: the slide shows the WACC build (and says
    # when beta was assumed), the stub fraction and valuation date, a
    # projections table with D&A and ΔNWC so unlevered FCF ties, the terminal
    # year, and the implied exit multiple / implied growth cross-checks.
    module Dcf
      F = Format

      module_function

      def build(ctx)
        field = ctx.field
        dcf = field[:dcf]
        a = dcf[:assumptions]
        build = field[:wacc] || {}
        cur = ctx.currency
        {
          title: "Discounted cash flow analysis",
          subtitle: "WACC #{Charts.fixed(a[:wacc].to_f * 100, decimals: 2)}% · #{dcf[:terminal_method]} · " \
                    "#{a[:mid_year_convention] ? 'mid-year' : 'year-end'} discounting",
          payload: {
            projections: dcf[:projections],
            terminal_year: dcf[:terminal_year],
            assumptions: a,
            wacc_build: build,
            beta_assumed: build[:beta_assumed] ? true : false,
            stub_fraction: dcf[:stub_fraction],
            valuation_date: dcf[:valuation_date],
            terminal_method: dcf[:terminal_method],
            terminal_value: dcf[:terminal_value],
            pv_explicit: dcf[:pv_explicit],
            pv_terminal: dcf[:pv_terminal],
            terminal_share_of_ev: dcf[:terminal_share_of_ev],
            implied_exit_multiple: dcf[:implied_exit_multiple],
            implied_terminal_growth: dcf[:implied_terminal_growth],
            enterprise_value: dcf[:enterprise_value],
            net_debt: dcf[:net_debt],
            other_claims: dcf[:other_claims],
            equity_value: dcf[:equity_value],
            value_per_share: dcf[:value_per_share],
            bridge_note: dcf[:bridge_note],
            share_price: F.present_number?(ctx.share_price) ? ctx.share_price : nil,
            currency: cur,
            notes: F.sentences(notes(dcf, a, build, cur)),
            note: F.sentences([value_sentence(dcf, cur)]).first.to_s
          }
        }
      end

      def value_sentence(dcf, cur)
        share = dcf[:terminal_share_of_ev].nil? ? "" : "; the terminal value accounts for #{F.pct(dcf[:terminal_share_of_ev])} of enterprise value"
        if dcf[:equity_value].nil? || dcf[:value_per_share].nil?
          return "Base-case enterprise value of #{F.money(dcf[:enterprise_value], cur)}#{share}. " \
                 "#{dcf[:bridge_note].presence || 'No share count is loaded, so no per-share value is stated.'}"
        end

        "Base case equity value of #{F.money(dcf[:equity_value], cur)} equates to #{F.price(dcf[:value_per_share], cur)} " \
          "per share#{share}."
      end

      def notes(dcf, a, build, cur)
        out = []
        valuation_date = dcf[:valuation_date]
        stub = dcf[:stub_fraction]
        if valuation_date && stub
          out << "Cash flows are discounted from the valuation date of #{F.date(valuation_date)}; the first projected " \
                 "year counts #{Charts.fixed(stub.to_f * 100, decimals: 0)}% of its cash flow (stub fraction #{Charts.fixed(stub, decimals: 2)})."
        end
        unless build.empty?
          text = +"WACC build: cost of equity #{F.pct(build[:cost_of_equity], 2)} (risk-free #{F.pct(build[:risk_free_rate], 2)} " \
                  "+ beta #{Charts.fixed(build[:beta], decimals: 2)} × equity risk premium #{F.pct(build[:equity_risk_premium], 2)}), " \
                  "after-tax cost of debt #{F.pct(build[:after_tax_cost_of_debt], 2)}, debt weight #{F.pct(build[:weight_debt])}, " \
                  "giving #{F.pct(build[:wacc], 2)}."
          out << text
          if build[:beta_assumed]
            out << "Beta was not loaded for this company, so a market beta of #{Charts.fixed(build[:beta], decimals: 2)} is assumed " \
                   "and the WACC is the house default build rather than company-specific."
          end
          if !build[:wacc].nil? && (a[:wacc].to_f - build[:wacc].to_f).abs > 1e-6
            out << "The deck's WACC of #{F.pct(a[:wacc], 2)} overrides the built-up #{F.pct(build[:wacc], 2)}."
          end
        end
        if a[:exit_multiple].nil?
          out << "Cross-check: the Gordon terminal value implies #{F.mult(dcf[:implied_exit_multiple])} final-year EBITDA." unless dcf[:implied_exit_multiple].nil?
        else
          out << "Cross-check: the #{F.mult(a[:exit_multiple])} exit multiple implies perpetual growth of #{F.pct(dcf[:implied_terminal_growth])}." unless dcf[:implied_terminal_growth].nil?
        end
        if dcf.dig(:terminal_year, :capex_floored_at_da)
          out << "Terminal-year capex is floored at D&A so the perpetuity does not assume the asset base shrinks."
        end
        out
      end
    end
  end
end
