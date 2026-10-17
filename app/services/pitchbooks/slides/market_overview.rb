# frozen_string_literal: true

module Pitchbooks
  module Slides
    # Market overview: the trending-theme model over the whole corpus, not a
    # stock paragraph.
    #
    # The reference closed with a fixed sentence ("the shift is one of emphasis
    # rather than of subject matter") whatever the data said. The narrative now
    # says the mix shifted toward a theme only when that theme's share of
    # documents actually rose by SHIFT_POINTS, and from another only when one
    # fell by as much; otherwise it says the topic mix is stable (item 19).
    # Themes come from Analytics.trending_themes, which already applies the
    # boilerplate stoplist.
    module MarketOverview
      F = Format
      WINDOW_DAYS = 180
      SHOWN = 8
      # Candidates scanned for a theme that lost share; the shown list is the top
      # of the same ranking.
      CANDIDATES = 40
      # Ten points of document share is a shift a reader would notice.
      SHIFT_POINTS = 0.10

      module_function

      def build(ctx)
        trending = Analytics.trending_themes(window_days: WINDOW_DAYS, limit: CANDIDATES)
        themes = trending[:themes].first(SHOWN)
        timeline = Analytics.sentiment_timeline(months: 24)
        volume = Analytics.volume_by_type(months: 24)
        {
          title: "#{ctx.metrics[:sector].presence || 'Sector'} — market overview",
          subtitle: "What the corpus says is changing",
          payload: {
            narrative: narrative(trending, themes),
            themes: themes,
            shift: shift(trending),
            sentiment_timeline: timeline,
            volume_by_type: volume,
            as_of: trending[:as_of],
            window_days: trending[:window_days]
          }
        }
      end

      def narrative(trending, themes)
        top = themes.first(3).map { |t| t[:theme] }
        recent = trending[:recent_documents].to_i
        parts = []
        parts << "Across #{recent} #{recent == 1 ? 'document' : 'documents'} published in the last #{trending[:window_days]} days, " \
                 "sector discussion has concentrated on #{top.any? ? top.to_sentence : 'no single dominant theme'}."
        moved = shift(trending)
        parts <<
          if trending[:baseline_documents].to_i.zero?
            "The corpus holds no documents from the preceding period, so no shift in the topic mix can be measured."
          elsif moved[:toward]
            toward = moved[:toward]
            text = +"The mix has shifted toward #{toward[:theme]} (#{share_text(toward)})"
            text << " from #{moved[:from][:theme]} (#{share_text(moved[:from])})" if moved[:from]
            "#{text}."
          else
            "Against the #{trending[:baseline_documents]} documents of the preceding period the topic mix is stable: " \
              "no theme's share of documents moved by #{(SHIFT_POINTS * 100).round} points or more."
          end
        parts.join(" ")
      end

      # The theme whose document share rose most, and the one whose share fell
      # most, when either moved by at least SHIFT_POINTS.
      def shift(trending)
        recent = trending[:recent_documents].to_i
        baseline = trending[:baseline_documents].to_i
        return { toward: nil, from: nil } if recent.zero? || baseline.zero?

        rows = trending[:themes].map do |t|
          now = t[:mentions].to_f / recent
          before = t[:prior_mentions].to_f / baseline
          { theme: t[:theme], recent_share: now.round(4), prior_share: before.round(4), change: (now - before).round(4) }
        end
        toward = rows.select { |r| r[:change] >= SHIFT_POINTS }.max_by { |r| r[:change] }
        from = rows.select { |r| r[:change] <= -SHIFT_POINTS }.min_by { |r| r[:change] }
        { toward: toward, from: toward ? from : nil }
      end

      def share_text(row)
        "#{F.pct(row[:recent_share], 0)} of recent documents against #{F.pct(row[:prior_share], 0)} before"
      end
    end
  end
end
