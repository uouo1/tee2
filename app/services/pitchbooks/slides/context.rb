# frozen_string_literal: true

module Pitchbooks
  module Slides
    # Everything a slide builder reads, computed once per rebuild (Python's
    # `context` dict). The football field, the target's metrics and its profile
    # are the expensive calls; every builder shares them.
    Context = Struct.new(:pitchbook, :ticker, :comps, :field, :metrics, :profile, :stamp, keyword_init: true) do
      def currency
        metrics[:currency].presence || "USD"
      end

      def basis
        metrics[:valuation_basis] || metrics[:latest_actual] || {}
      end

      # "LTM Jun-26" / "FY2025": printed beside every multiple (item 17).
      def basis_label
        metrics[:basis_label].presence || basis[:basis].presence || "FY#{basis[:fiscal_year]}"
      end

      def comp_rows
        field.dig(:comps, :rows) || []
      end

      # The target's EBITDA margin on the valuation basis.
      def target_margin
        basis[:ebitda_margin]
      end

      # Median EBITDA margin across the comp rows that report one; nil with no peers.
      # Profitability is argued against this, not against a fixed 22% bar (item 7).
      def peer_margins
        comp_rows.filter_map { |row| row[:ebitda_margin]&.to_f }
      end

      def peer_median_margin
        Valuation.percentile(peer_margins, 0.5)
      end

      def share_price
        metrics[:share_price]
      end

      def price_date
        metrics[:as_of]
      end

      def concluded
        field[:concluded_range] || {}
      end

      def precedent_premium
        field.dig(:precedents, :stats, :premium_1day) || {}
      end

      def ntm
        metrics[:ntm]
      end
    end
  end
end
