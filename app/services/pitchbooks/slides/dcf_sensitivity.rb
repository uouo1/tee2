# frozen_string_literal: true

module Pitchbooks
  module Slides
    module DcfSensitivity
      module_function

      def build(ctx)
        field = ctx.field
        sens = field[:sensitivity]
        {
          title: "DCF sensitivity",
          subtitle: "Implied value per share across WACC and terminal growth",
          payload: {
            wacc_axis: sens[:wacc_axis],
            terminal_axis: sens[:terminal_axis],
            grid: sens[:grid],
            min: sens[:min],
            max: sens[:max],
            reference_price: Format.present_number?(field[:reference_price]) ? field[:reference_price] : nil,
            currency: field.dig(:target, :currency) || ctx.currency,
            bridge_note: field.dig(:dcf, :bridge_note)
          }
        }
      end
    end
  end
end
