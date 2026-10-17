# frozen_string_literal: true

module Backtest
  # Monthly bars and split events for every member with a ticker; members with
  # no bars are marked as dropouts so the survivorship bias is counted.
  module Prices
    module_function

    def build!(anchor_year: 2016, cache: true, progress: nil, today: Date.today)
      members = UniverseMember.where(anchor_year: anchor_year).where.not(ticker: nil).order(:id)
      totals = { companies: 0, with_prices: 0, bars: 0, splits: 0, by_source: Hash.new(0), no_price_history: 0 }
      members.each_with_index do |member, index|
        history = Sources::PriceHistory.history(member.ticker, cache: cache, today: today)
        bars = history[:bars]
        totals[:companies] += 1
        if bars.empty?
          member.update!(has_prices: false, dropout_reason: member.dropout_reason || "no_price_history")
          totals[:no_price_history] += 1
        else
          PriceBar.where(ticker: member.ticker).delete_all
          rows = bars.map { |bar| bar.merge(ticker: member.ticker) }
          rows.each_slice(500) { |slice| PriceBar.insert_all(slice, unique_by: %i[ticker month_end]) }
          SplitEvent.where(ticker: member.ticker).delete_all
          unless history[:splits].empty?
            SplitEvent.insert_all(
              history[:splits].map { |split| split.merge(ticker: member.ticker, source: bars.first[:source]) },
              unique_by: %i[ticker date]
            )
          end
          # Only the price-leg dropout is cleared here: a member dropped for
          # another reason (not a filer in the anchor year) stays dropped.
          reason = member.dropout_reason == "no_price_history" ? nil : member.dropout_reason
          member.update!(has_prices: true, dropout_reason: reason)
          totals[:with_prices] += 1
          totals[:bars] += rows.size
          totals[:splits] += history[:splits].size
          totals[:by_source][bars.first[:source]] += 1
        end
        progress&.call(index + 1, members.size, member.ticker)
      end
      totals
    end
  end
end
