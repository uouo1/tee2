# frozen_string_literal: true

module Pitchbooks
  module Slides
    # Executive summary: where the stock trades, what the methods imply, how the
    # business compares with its peers, and what its own disclosure says.
    #
    # Deliberate changes from argos/pitchbook.py (RAILS_PORT.md items 16, 17, 19):
    # the implied range is stated against the price without calling the gap
    # "upside" (the repository's own backtest found no evidence that cheap
    # versus peers predicts returns); every multiple names its period; and
    # profitability is compared with the peer median margin, with both numbers,
    # instead of a fixed 22% threshold that called every company "in line".
    module ExecutiveSummary
      F = Format
      # Within two margin points of the peer median reads as "in line".
      IN_LINE_BAND = 0.02
      RESEARCH_QUERY = "guidance OR margin OR demand OR pricing OR retention"

      module_function

      def build(ctx)
        metrics = ctx.metrics
        bullets = F.sentences([trading_sentence(ctx), range_sentence(ctx), profitability_sentence(ctx)]).map { |t| { text: t } }

        # Pull the research module's own view of the name, with citations. The
        # query is OR-ed on purpose: an AND across every theme word matches nothing.
        research = Search.search(RESEARCH_QUERY, { ticker: metrics[:ticker] }, limit: 8, summarize: true)
        summary = research[:summary] || {}
        Array(summary[:bullets]).first(3).each do |bullet|
          next if F.na_inside?(bullet[:text])

          bullets << {
            text: bullet[:text],
            source: {
              document_id: bullet[:document_id], title: bullet[:title],
              published_at: bullet[:published_at], doc_type: bullet[:doc_type]
            }
          }
        end

        # Themes grounded in the passages the research query actually matched;
        # the per-company trend model is too thin on a handful of filings to
        # quote. Keyword extraction does not know filing boilerplate, so the
        # themes pass Analytics' stoplist before they reach prose (item 19).
        themes = Array(summary[:themes]).map { |t| t[:theme].to_s }
                                       .select { |t| t.length >= 5 }
                                       .reject { |t| Analytics.boilerplate_theme?(t) }
                                       .first(4)
        if themes.any?
          bullets << { text: "Recurring themes in the company's own disclosure on these topics: #{themes.join(', ')}." }
        end

        tone = tone_sentence(ctx.profile)
        bullets << { text: tone } if tone

        {
          title: "Executive summary",
          subtitle: "#{metrics[:name]} — situation assessment",
          payload: {
            bullets: bullets,
            reference_range: ctx.concluded,
            share_price: F.present_number?(ctx.share_price) ? ctx.share_price : nil,
            price_date: ctx.price_date,
            currency: ctx.currency,
            basis_label: ctx.basis_label,
            target_margin: ctx.target_margin,
            peer_median_margin: ctx.peer_median_margin,
            peer_count: ctx.peer_margins.size
          }
        }
      end

      # "NovaGrid (NVG) trades at $44.10 per share …, or 17.5x FY2026 EBITDA and
      # 15.6x NTM EBITDA." Each clause only when its figure exists.
      def trading_sentence(ctx)
        m = ctx.metrics
        return nil unless F.present_number?(m[:share_price])

        cur = ctx.currency
        text = +"#{m[:name]} (#{m[:ticker]}) trades at #{F.price(m[:share_price], cur)} per share"
        text << " (price date #{F.date(m[:as_of])})" if m[:as_of].present?
        text << ", a market capitalisation of #{F.money(m[:market_cap], cur)}" if F.present_number?(m[:market_cap])
        if m[:enterprise_value].nil?
          text << "; enterprise value is not stated because net debt is not loaded"
        else
          text << " and an enterprise value of #{F.money(m[:enterprise_value], cur)}"
          multiples = []
          ltm = F.multiple_on(ctx.basis[:ev_ebitda], ctx.basis_label, "EBITDA")
          multiples << ltm if ltm
          ntm = ctx.ntm
          if ntm && !ntm[:ev_ebitda].nil?
            multiples << "#{F.mult(ntm[:ev_ebitda])} NTM EBITDA#{ntm[:ebitda_derived] ? ' (derived at current margin)' : ''}"
          end
          text << ", or #{multiples.join(' and ')}" if multiples.any?
        end
        "#{text}."
      end

      def range_sentence(ctx)
        concluded = ctx.concluded
        cur = ctx.currency
        if concluded[:low].nil? || concluded[:high].nil?
          reason = ctx.field[:dcf_note].presence
          return "The valuation methods could not be bridged to a per-share value#{reason ? " (#{reason.sub(/\.\z/, '')})" : ''}, " \
                 "so no implied range is stated."
        end

        methods = Array(concluded[:methods])
        text = +"Implied value at peer multiples and DCF of #{F.price(concluded[:low], cur)}–#{F.price(concluded[:high], cur)} per share"
        text << " (median low to median high of #{methods.size} #{methods.size == 1 ? 'method' : 'methods'})" if methods.any?
        text << ", against the current #{F.price(ctx.share_price, cur)}" if F.present_number?(ctx.share_price)
        "#{text}."
      end

      # Above / in line / below the PEER MEDIAN margin, quoting both (item 19).
      def profitability_sentence(ctx)
        margin = ctx.target_margin
        return nil if margin.nil?

        cur = ctx.currency
        label = ctx.basis_label
        revenue = ctx.basis[:revenue]
        lead = F.present_number?(revenue) ? "#{label} revenue of #{F.money(revenue, cur)} at a #{F.pct(margin)} EBITDA margin" : "A #{label} EBITDA margin of #{F.pct(margin)}"
        median = ctx.peer_median_margin
        ev_revenue = F.multiple_on(ctx.basis[:ev_revenue], label, "EV/Revenue")
        tail = ev_revenue ? ", on #{ev_revenue}" : ""
        return "#{lead}; no peer margins are loaded for a comparison#{tail}." if median.nil?

        gap = margin.to_f - median
        position =
          if gap.abs <= IN_LINE_BAND then "in line with"
          elsif gap.positive? then "above"
          else "below"
          end
        peers = ctx.peer_margins.size
        "#{lead} places the company #{position} the peer median of #{F.pct(median)} " \
          "across #{peers} #{peers == 1 ? 'peer' : 'peers'}#{tail}."
      end

      def tone_sentence(profile)
        sentiment = profile[:sentiment]
        return nil if sentiment.nil?

        reading =
          if sentiment >= 0.18 then "supportive of a sale process narrative"
          elsif sentiment <= -0.18 then "a reason to pre-empt diligence questions on momentum"
          else "neither a tailwind nor a headwind for a process narrative"
          end
        label = profile[:sentiment_label].presence || Nlp.sentiment_label(sentiment)
        "Corpus tone across #{profile[:document_count].to_i} documents is #{label} " \
          "(#{Charts.fixed(sentiment, decimals: 2, sign: true)} on a −1 to +1 scale), which we read as #{reading}."
      end
    end
  end
end
