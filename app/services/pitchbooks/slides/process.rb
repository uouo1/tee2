# frozen_string_literal: true

module Pitchbooks
  module Slides
    # Process considerations and next steps.
    #
    # Changes from the reference (items 16 and 19): the implied range is stated
    # against the price, not as a "+x% move"; leverage is phrased from the net
    # debt / EBITDA band with its numbers instead of always "modest"; the
    # SaaS-specific "subscription pricing" diligence bullet is replaced by a
    # generic one plus the company's own most prominent themes.
    module Process
      F = Format

      module_function

      def build(ctx)
        cur = ctx.currency
        concluded = ctx.concluded
        price = ctx.share_price
        bullets = []
        bullets <<
          if concluded[:low].nil? || concluded[:high].nil?
            "The valuation methods could not be bridged to a per-share value, so no implied range is stated; " \
              "resolve the missing inputs (net debt, share count) before the valuation discussion."
          elsif F.present_number?(price)
            "Implied value at peer multiples and DCF of #{F.price(concluded[:low], cur)}–#{F.price(concluded[:high], cur)} " \
              "per share, against the current #{F.price(price, cur)}#{ctx.price_date ? " (#{F.date(ctx.price_date)})" : ''}."
          else
            "Implied value at peer multiples and DCF of #{F.price(concluded[:low], cur)}–#{F.price(concluded[:high], cur)} per share."
          end

        premium = ctx.precedent_premium
        bullets <<
          if !premium[:median].nil? && F.present_number?(price) && !premium[:p25].nil? && !premium[:p75].nil?
            "Precedent one-day premia have clustered between #{F.pct(premium[:p25])} and #{F.pct(premium[:p75])}; " \
              "applying the median #{F.pct(premium[:median])} to the current price gives " \
              "#{F.price(price * (1 + premium[:median]), cur)} per share."
          else
            "No precedent transactions are loaded, so the control premium is unquantified here; load a deal screen " \
              "(`bin/rails \"argos:load_transactions[deals.csv]\"`) before the valuation discussion."
          end

        bullets << leverage_bullet(ctx)
        bullets << diligence_bullet(ctx)
        bullets << "Suggested next steps: agree the comp set and base-case assumptions, confirm the counterparty list, " \
                   "and prepare a management presentation around the themes identified in the market overview."
        { title: "Process considerations and next steps", payload: { bullets: F.sentences(bullets) } }
      end

      def leverage_bullet(ctx)
        m = ctx.metrics
        cur = ctx.currency
        clause = F.leverage(m[:net_debt], ctx.basis[:ebitda], ctx.basis_label, cur)
        return "Net debt is not loaded for the target, so leverage capacity is not assessed; confirm the balance sheet before structuring." if clause.nil?

        consequence =
          case F.leverage_band(m[:net_debt], ctx.basis[:ebitda])
          when :net_cash then "leaving full debt capacity for a leveraged structure"
          when :below_1x then "leaving room for a leveraged structure"
          when :one_to_three then "leaving limited room for incremental acquisition debt"
          else "which constrains a leveraged structure"
          end
        "#{clause.upcase_first}, #{consequence}."
      end

      def diligence_bullet(ctx)
        text = +"Diligence focus: the bridge from reported GAAP operating income to EBITDA, revenue quality and " \
                "customer concentration, and working-capital needs as growth changes"
        # Phrases first: a two-word theme says more than a lone token.
        themes = Array(ctx.profile[:themes]).map { |t| t[:theme].to_s }
                                            .reject { |t| t.length < 4 || Analytics.boilerplate_theme?(t) }
                                            .each_with_index.sort_by { |t, i| [t.include?(" ") ? 0 : 1, i] }
                                            .map(&:first).first(3)
        text << "; and the topics the company's own disclosure keeps returning to: #{themes.join(', ')}" if themes.any?
        "#{text}."
      end
    end
  end
end
