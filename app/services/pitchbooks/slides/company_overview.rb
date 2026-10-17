# frozen_string_literal: true

module Pitchbooks
  module Slides
    # Company overview: capital structure tiles on the valuation basis, plus the
    # KPIs the corpus extracted from the company's own documents.
    module CompanyOverview
      F = Format

      module_function

      def build(ctx)
        m = ctx.metrics
        cur = ctx.currency
        basis = ctx.basis
        label = ctx.basis_label
        kpis = [
          { label: "Share price", value: F.present_number?(m[:share_price]) ? F.price(m[:share_price], cur) : F::NA },
          { label: "Market capitalisation", value: F.present_number?(m[:market_cap]) ? F.money(m[:market_cap], cur) : F::NA },
          { label: "Enterprise value", value: F.money(m[:enterprise_value], cur) },
          { label: "Net debt", value: F.money(m[:net_debt], cur) },
          { label: "#{label} revenue", value: F.money(basis[:revenue], cur) },
          { label: "#{label} EBITDA", value: "#{F.money(basis[:ebitda], cur)} (#{F.pct(basis[:ebitda_margin])})" },
          { label: "EV / EBITDA (#{label})", value: F.mult(basis[:ev_ebitda]) },
          { label: "Employees", value: m[:employees].present? ? Charts.number(m[:employees]) : F::NA }
        ]
        if ctx.ntm && !ctx.ntm[:ev_ebitda].nil?
          kpis.insert(7, {
            label: "EV / NTM EBITDA",
            value: "#{F.mult(ctx.ntm[:ev_ebitda])}#{ctx.ntm[:ebitda_derived] ? ' (derived at current margin)' : ''}"
          })
        end

        # A KPI whose newest sentence is a segment column or a table row is not a
        # company-level figure (item 20): it stays off the slide rather than
        # being presented as the headline number. Each tile carries its period
        # and whether the sentence quoted an adjusted or a GAAP measure.
        extracted = Array(ctx.profile[:kpis]).reject { |k| k[:latest].nil? || k[:segment_or_table] }.first(6).map do |k|
          {
            label: k[:measure].present? ? "#{k[:label]} (#{k[:measure]})" : k[:label],
            value: "#{Charts.fixed(k[:latest], decimals: 1)}#{k[:unit] == '%' ? '%' : ''}",
            observations: k[:observations],
            unit: k[:unit],
            period: k[:period],
            measure: k[:measure]
          }
        end

        subtitle = [m[:industry], m[:hq]].compact_blank.join(" · ")
        {
          title: "#{m[:name]} — company overview",
          subtitle: subtitle.presence,
          payload: {
            description: m[:description],
            kpis: kpis,
            extracted_kpis: extracted,
            sector: m[:sector],
            country: m[:country],
            basis_label: label,
            price_date: m[:as_of],
            balance_sheet_date: m[:net_debt_as_of],
            debt_note: m[:debt_note]
          }
        }
      end
    end
  end
end
