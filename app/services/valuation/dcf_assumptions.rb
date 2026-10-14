# frozen_string_literal: true

module Valuation
  # Inputs for the discounted cash flow. Rates are decimals.
  #
  # An immutable Data value: a run is reproducible from its assumptions, and the
  # assumptions are echoed back in every `run_dcf` result (see `to_h`), which is
  # what makes the DCF slide auditable.
  #
  # Defaults so a *partial* override hash (what the UI and API send) can be
  # coerced without having to restate the whole model; `run_dcf` validates.
  class DcfAssumptions < Data.define(
    :base_revenue, :revenue_growth, :growth_fade, :ebitda_margin, :margin_expansion,
    :da_pct_revenue, :capex_pct_revenue, :nwc_pct_revenue, :tax_rate, :wacc,
    :terminal_growth, :exit_multiple, :years, :net_debt, :shares_diluted,
    :mid_year_convention, :start_year
  )
    INTEGER_FIELDS = %i[years start_year].freeze
    BOOLEAN_FIELDS = %i[mid_year_convention].freeze

    def initialize(
      base_revenue: 0.0,
      revenue_growth: 0.12,
      growth_fade: 0.15,          # fraction of growth given back each year
      ebitda_margin: 0.25,
      margin_expansion: 0.004,    # annual change in EBITDA margin
      da_pct_revenue: 0.05,
      capex_pct_revenue: 0.04,
      nwc_pct_revenue: 0.012,     # change in net working capital
      tax_rate: Valuation::DEFAULT_TAX_RATE,
      wacc: Valuation::DEFAULT_WACC,
      terminal_growth: Valuation::DEFAULT_TERMINAL_GROWTH,
      exit_multiple: nil,         # when set, terminal value = exit_multiple x terminal EBITDA
      years: Valuation::PROJECTION_YEARS,
      net_debt: 0.0,
      shares_diluted: 1.0,
      mid_year_convention: true,
      start_year: 2027
    )
      super
    end

    # Type-coerce a partial assumptions hash, dropping unknown/blank keys.
    #
    # Keys may be strings or symbols: the API hands over parsed JSON and the
    # assumptions form hands over params, and neither should have to know which
    # spelling the model prefers. Values are cast to the field's type, so "0.08"
    # from a form field and 0.08 from JSON land identically.
    def self.coerce(payload)
      clean = {}
      (payload || {}).each do |key, value|
        key = key.to_s.to_sym
        next unless members.include?(key)
        next if value.nil? || value == ""

        clean[key] =
          if INTEGER_FIELDS.include?(key)
            Integer(value)
          elsif BOOLEAN_FIELDS.include?(key)
            # Form params arrive as strings; "false" and "0" must mean false
            # (Python's bool() would have read any non-empty string as true).
            ActiveModel::Type::Boolean.new.cast(value)
          else
            Float(value)
          end
      end
      clean
    end

    # Build from a partial hash (Python's `from_dict`).
    def self.from_h(payload)
      new(**coerce(payload))
    end

    # A copy with only the supplied assumptions replaced.
    def with_overrides(payload)
      with(**self.class.coerce(payload))
    end
  end
end
