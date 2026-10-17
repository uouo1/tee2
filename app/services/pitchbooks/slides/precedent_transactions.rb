# frozen_string_literal: true

module Pitchbooks
  module Slides
    module PrecedentTransactions
      F = Format

      module_function

      def build(ctx)
        precedents = ctx.field[:precedents]
        stats = precedents[:stats]
        {
          title: "Precedent transactions",
          subtitle: "Announced transactions in the sector",
          payload: { rows: precedents[:rows], stats: stats, note: note(precedents[:rows], stats) }
        }
      end

      def note(rows, stats)
        if rows.empty?
          return "No precedent transactions are loaded for this sector. Deal multiples are not available from " \
                 "public filings in a consistent form; load a transaction screen with " \
                 "`bin/rails \"argos:load_transactions[deals.csv]\"` and rebuild the deck to populate this page and " \
                 "the precedent range on the valuation summary."
        end

        ebitda = stats[:ev_ebitda] || {}
        premium = stats[:premium_1day] || {}
        parts = []
        parts << "median EV/EBITDA of #{F.mult(ebitda[:median])} across #{ebitda[:count]} transactions" unless ebitda[:median].nil?
        parts << "a median one-day premium of #{F.pct(premium[:median])} across #{premium[:count]}" unless premium[:median].nil?
        return "#{rows.size} transactions loaded; none reports an EV/EBITDA multiple or a premium." if parts.empty?

        "#{parts.join(', on ').upcase_first}."
      end
    end
  end
end
