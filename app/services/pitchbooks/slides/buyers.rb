# frozen_string_literal: true

module Pitchbooks
  module Slides
    # Potential counterparties: the comp set as strategic buyers, plus sponsors.
    #
    # The reference called any higher-margin peer's profile "accretive" and
    # said it "supports a cash offer", and any peer at least the target's size
    # had "balance-sheet capacity". Rationale now states each peer's actual
    # margin and EV/EBITDA against the target's (item 19), and claims
    # balance-sheet capacity only for a peer at least twice the target's
    # enterprise value with net debt / EBITDA below 3x.
    module Buyers
      F = Format
      CAPACITY_SIZE = 2.0
      CAPACITY_LEVERAGE = 3.0

      module_function

      def build(ctx)
        m = ctx.metrics
        cur = ctx.currency
        target_ev = m[:enterprise_value]
        sentiments = peer_sentiments(ctx.comp_rows.map { |r| r[:ticker] })
        candidates = ctx.comp_rows.map do |row|
          relative = F.present_number?(target_ev) && !row[:enterprise_value].nil? ? (row[:enterprise_value].to_f / target_ev.to_f) : nil
          {
            name: row[:name],
            ticker: row[:ticker],
            type: "Strategic",
            enterprise_value: row[:enterprise_value],
            relative_size: relative&.round(2),
            ebitda_margin: row[:ebitda_margin],
            ev_ebitda: row[:ev_ebitda],
            leverage: F.leverage_ratio(row[:net_debt], row[:ebitda])&.round(2),
            sentiment: sentiments[row[:ticker]],
            rationale: rationale(row, relative, ctx)
          }
        end
        # Largest first; the original index breaks ties like Python's stable sort.
        candidates = candidates.each_with_index.sort_by { |c, i| [-(c[:enterprise_value] || 0), i] }.map(&:first)

        sponsors = [{
          name: "Financial sponsors", ticker: "—", type: "Sponsor",
          enterprise_value: nil, relative_size: nil, sentiment: nil,
          rationale: sponsor_note(ctx)
        }]
        {
          title: "Potential counterparties",
          subtitle: "Indicative, based on scale, margin, multiple and leverage",
          payload: { candidates: candidates.first(6) + sponsors, target_enterprise_value: target_ev, currency: cur, basis_label: ctx.basis_label }
        }
      end

      # Mean document tone per peer, without building a full company profile
      # for each (the reference did, and only used this one number).
      def peer_sentiments(tickers)
        return {} if tickers.empty?

        Document.joins(:company).where(companies: { ticker: tickers }).group("companies.ticker").average(:sentiment)
                .transform_values { |v| v&.to_f&.round(3) }
      end

      def rationale(row, relative, ctx)
        cur = ctx.currency
        label = ctx.basis_label
        parts = []
        unless relative.nil?
          size = "EV of #{F.money(row[:enterprise_value], cur)} is #{F.mult(relative)} the target's"
          leverage = F.leverage_ratio(row[:net_debt], row[:ebitda])
          parts <<
            if relative >= CAPACITY_SIZE && !leverage.nil? && leverage < CAPACITY_LEVERAGE
              "#{size} with net debt / EBITDA of #{F.mult(leverage)}: balance-sheet capacity to absorb the target"
            elsif relative >= CAPACITY_SIZE && !leverage.nil?
              "#{size} but net debt / EBITDA of #{F.mult(leverage)} limits debt funding"
            elsif relative >= CAPACITY_SIZE
              "#{size}; its net debt is not loaded, so funding capacity is not assessed"
            elsif relative >= 0.5
              "#{size}: a merger-of-equals structure would be required"
            else
              "#{size}: would need significant equity or a consortium"
            end
        end
        target_margin = ctx.target_margin
        if !row[:ebitda_margin].nil? && !target_margin.nil?
          parts << "#{label} EBITDA margin of #{F.pct(row[:ebitda_margin])} against the target's #{F.pct(target_margin)}"
        end
        target_multiple = ctx.basis[:ev_ebitda]
        if !row[:ev_ebitda].nil? && !target_multiple.nil?
          text = +"trades at #{F.mult(row[:ev_ebitda])} #{row[:basis].presence || label} EV/EBITDA against the target's #{F.mult(target_multiple)}"
          text << ", so its shares are the richer currency" if row[:ev_ebitda].to_f > target_multiple.to_f
          parts << text
        end
        parts = F.sentences(parts)
        parts.empty? ? "Not enough market data loaded to compare with the target." : parts.join("; ")
      end

      def sponsor_note(ctx)
        m = ctx.metrics
        cur = ctx.currency
        parts = []
        leverage = F.leverage(m[:net_debt], ctx.basis[:ebitda], ctx.basis_label, cur)
        parts << "Target #{leverage}" if leverage
        premium = ctx.precedent_premium
        parts <<
          if premium[:median].nil?
            "no precedent premium data loaded"
          else
            "precedent deals in the sector cleared at a median #{F.pct(premium[:median])} one-day premium"
          end
        F.sentences(parts).join("; ")
      end
    end
  end
end
