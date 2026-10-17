# frozen_string_literal: true

module Pitchbooks
  module Slides
    # Trading comparables with the target in the first row.
    #
    # Item 17: every multiple names its period (`basis` per row), and the slide
    # carries the price date, the balance-sheet date, which share count the
    # per-share figures rest on, the NTM columns, and what "EBITDA" means here.
    module TradingComps
      EBITDA_FOOTNOTE = "EBITDA = GAAP operating income plus D&A, unadjusted (no add-backs for stock-based " \
                        "compensation, restructuring or other items); multiples are on each company's latest " \
                        "twelve months where a 10-Q allows, else its last fiscal year, as labelled per row."

      module_function

      def build(ctx)
        m = ctx.metrics
        basis = ctx.basis
        comps = ctx.field[:comps]
        target_row = {
          ticker: m[:ticker], name: m[:name], is_target: true,
          share_price: Format.present_number?(m[:share_price]) ? m[:share_price] : nil,
          price_date: m[:as_of],
          market_cap: Format.present_number?(m[:market_cap]) ? m[:market_cap] : nil,
          enterprise_value: m[:enterprise_value], net_debt: m[:net_debt], net_debt_as_of: m[:net_debt_as_of],
          shares_diluted: m[:shares_diluted], shares_basic: m[:shares_basic],
          revenue: basis[:revenue]&.round(1),
          ebitda: basis[:ebitda]&.round(1),
          ebitda_margin: basis[:ebitda_margin],
          ev_revenue: basis[:ev_revenue],
          ev_ebitda: basis[:ev_ebitda],
          pe: basis[:pe],
          fiscal_year: basis[:fiscal_year],
          basis: ctx.basis_label,
          ev_revenue_ntm: ctx.ntm&.dig(:ev_revenue),
          ev_ebitda_ntm: ctx.ntm&.dig(:ev_ebitda),
          pe_ntm: ctx.ntm&.dig(:pe),
          ntm_ebitda_derived: ctx.ntm&.dig(:ebitda_derived)
        }
        rows = comps[:rows].map { |row| row.merge(share_basis: share_basis(row)) }
        target_row[:share_basis] = share_basis(target_row)
        all = [target_row] + rows
        {
          title: "Trading comparables",
          subtitle: "#{m[:sector]} · #{ctx.currency}m except per-share and multiples",
          payload: {
            target: target_row,
            rows: rows,
            stats: comps[:stats],
            labels: comps[:labels],
            bases: comps[:bases],
            currency: ctx.currency,
            basis_label: ctx.basis_label,
            price_date: all.filter_map { |r| r[:price_date] }.max,
            balance_sheet_date: all.filter_map { |r| r[:net_debt_as_of] }.max,
            share_count_basis: share_count_note(all),
            has_ntm: all.any? { |r| !r[:ev_ebitda_ntm].nil? },
            ntm_derived: all.any? { |r| r[:ntm_ebitda_derived] },
            footnote: EBITDA_FOOTNOTE
          }
        }
      end

      # Which share count a row's per-share figures rest on. The loader stores
      # the diluted weighted average in shares_diluted and the cover-page count
      # in shares_basic, and falls back to the cover count when no diluted
      # figure was filed (then the two are equal).
      def share_basis(row)
        diluted = row[:shares_diluted]
        basic = row[:shares_basic]
        return nil unless Format.present_number?(diluted)
        return "diluted" if basic.nil?
        return "cover-page" if (diluted.to_f - basic.to_f).abs < 1e-6

        "diluted WA"
      end

      def share_count_note(rows)
        bases = rows.filter_map { |r| r[:share_basis] }.tally
        return "No share counts loaded." if bases.empty?

        parts = bases.map do |basis, n|
          case basis
          when "diluted WA" then "#{n} on the diluted weighted-average count (shares_diluted) rather than the cover-page count (shares_basic)"
          when "cover-page" then "#{n} on the cover-page count (shares_basic; no diluted count filed)"
          else "#{n} on the loaded diluted count (shares_diluted; no cover-page count loaded)"
          end
        end
        "Per-share figures: #{parts.join('; ')}."
      end
    end
  end
end
