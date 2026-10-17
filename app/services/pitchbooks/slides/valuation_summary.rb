# frozen_string_literal: true

module Pitchbooks
  module Slides
    # Football field. Each range carries in_conclusion / reference / note from
    # Valuation.football_field, so the slide can show the 52-week range and an
    # excluded revenue multiple without letting either set the conclusion.
    module ValuationSummary
      module_function

      def build(ctx)
        field = ctx.field
        concluded = field[:concluded_range] || {}
        {
          title: "Valuation summary",
          subtitle: "Implied value per share, #{ctx.currency} · multiples on #{ctx.basis_label}",
          payload: {
            ranges: field[:ranges].map do |r|
              r.slice(:method, :low, :high, :mid, :basis, :detail, :in_conclusion, :reference, :note)
            end,
            reference_price: Format.present_number?(field[:reference_price]) ? field[:reference_price] : nil,
            concluded_range: concluded,
            methods: Array(concluded[:methods]),
            axis: field[:axis],
            currency: ctx.currency,
            basis_label: ctx.basis_label,
            price_date: ctx.price_date,
            dcf_note: field[:dcf_note]
          }
        }
      end
    end
  end
end
