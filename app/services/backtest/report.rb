# frozen_string_literal: true

module Backtest
  # A Markdown report plus two SVG charts for a stored run, written where the
  # repository can show them (docs/backtests/). The biases section is never
  # optional.
  module Report
    module_function

    def write(run, dir: Rails.root.join("docs", "backtests"))
      dir = Pathname(dir)
      dir.mkpath
      r = run.results_hash
      slug = run.name.to_s.downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-|-\z/, "")
      horizons = r[:horizons] || {}

      ic_by_h = Charts.diverging_bar_svg(
        horizons.keys.map { |h| "#{h}m" },
        horizons.values.map { |v| (v[:mean_ic] || 0).to_f },
        title: "Mean monthly rank IC by horizon", value_format: ->(v) { format("%+.3f", v) }
      )
      twelve = horizons[:"12"] || horizons["12"] || horizons.values.last || {}
      series = twelve[:series] || []
      ic_over_time = Charts.line_chart_svg(
        series.map { |s| s[:date].to_s[0, 7] }, series.map { |s| s[:ic].to_f },
        title: "12-month rank IC by date", value_format: ->(v) { format("%+.2f", v) }
      )
      spread_over_time = Charts.line_chart_svg(
        series.map { |s| s[:date].to_s[0, 7] }, series.map { |s| s[:spread].to_f * 100 },
        title: "12-month Q1−Q5 (cheap minus rich) return spread by date, %", value_format: ->(v) { format("%+.1f", v) }
      )
      File.write(dir.join("#{slug}-ic-by-horizon.svg"), wrap_svg(ic_by_h))
      File.write(dir.join("#{slug}-ic-12m.svg"), wrap_svg(ic_over_time))
      File.write(dir.join("#{slug}-spread-12m.svg"), wrap_svg(spread_over_time))

      md = +"# Backtest: #{run.name}\n\n"
      md << "Run #{run.id} on #{run.created_at.to_date}. Method: `docs/BACKTEST.md`.\n\n"
      u = r[:universe] || {}
      d = r[:data] || {}
      md << "## Universe and data\n\n"
      md << "| | |\n|---|---:|\n"
      md << "| Anchor year | #{u[:anchor_year]} |\n| Members selected | #{u[:members]} |\n"
      md << "| With a current ticker | #{u[:with_ticker]} |\n| Dropped: no current ticker (upper bound on delistings; includes debt-only subsidiaries and renamed CIKs) | #{u[:no_current_ticker]} |\n"
      md << "| Dropped: not a filer in the anchor year | #{u[:not_a_filer_in_anchor_year] || 0} |\n"
      md << "| Dropped: no price history | #{u[:no_price_history]} |\n| **Priced and evaluated** | **#{u[:priced]}** |\n"
      md << "| Names that received a signal on at least one date | #{d[:names_ever_with_signal] || 'n/a'} |\n"
      md << "| Median anchor-year revenue | #{money(u[:median_revenue_anchor])} |\n"
      md << "| Point-in-time fact rows | #{d[:pit_fact_rows]} |\n| Price bars | #{d[:price_bars]} (#{d[:unadjusted_bars]} unadjusted fallback) |\n"
      md << "| Split events applied | #{d[:split_events] || 0} |\n"
      md << "| Dates | #{r.dig(:dates, :first)} → #{r.dig(:dates, :last)} (#{r.dig(:dates, :count)} month-ends) |\n\n"

      if r[:rules]
        md << "## Construction rules\n\n"
        r[:rules].each { |rule| md << "- #{rule}\n" }
        md << "\n"
      end
      if r[:exclusions].present?
        md << "## Why names drop out of a cross-section (name-dates, all dates)\n\n| Reason | Name-dates |\n|---|---:|\n"
        r[:exclusions].each do |reason, count|
          label = reason.to_s == "ebitda_mixed_periods" ? "ebitda_mixed_periods (operating income and D&A from different years; counted, not excluded)" : reason
          md << "| #{label} | #{count} |\n"
        end
        md << "\n"
      end

      md << "## Results — comps signal, long-only cross-section\n\n"
      md << "Signal: `#{r.dig(:params, :signal)}`; positive = cheap versus peers. IC is the Spearman rank correlation between the signal and the forward return across names on one date; the t-statistic uses Newey–West with h−1 lags for the overlapping windows.\n\n"
      md << "| Horizon | Dates | Avg names | Mean IC | SD IC | t IC (NW) | IC hit rate | Q1 (cheap) | Q5 (rich) | Q1−Q5 ann. | t spread (NW) | Names-with-signal ann. |\n"
      md << "|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|\n"
      horizons.each do |h, v|
        next if v[:n_dates].to_i.zero?

        md << "| #{h}m | #{v[:n_dates]} | #{v[:avg_names]} | #{v[:mean_ic]} | #{v[:sd_ic]} | #{v[:t_newey_west]} | #{rate(v[:hit_rate])} "
        md << "| #{pct(v[:mean_q1_return])} | #{pct(v[:mean_q5_return])} | #{pct(v[:spread_annualised])} | #{v[:t_spread_newey_west] || 'n/a'} | #{pct(v[:benchmark_annualised])} |\n"
      end
      md << "\n![Mean IC by horizon](#{slug}-ic-by-horizon.svg)\n\n![12-month IC by date](#{slug}-ic-12m.svg)\n\n![12-month Q1−Q5 spread by date](#{slug}-spread-12m.svg)\n\n"

      md << "## How to read it\n\n"
      md << "A mean IC near zero with a t-statistic inside ±2 means the signal did not rank future returns in this sample. "
      md << "A positive IC with |t| above 2 and a hit rate well above 50% would be evidence that cheap-versus-peers, as the pitch book defines it, carried information — before costs, in this universe, over this window. "
      md << "The Q1−Q5 column is the mean return of the cheapest fifth minus the richest fifth; read it with its own t-statistic, which adjusts for the overlapping windows, not on its own. "
      md << "A hit rate below 50% beside a positive mean IC means a few dates carry the mean. "
      md << "The last column is the equal-weight return of the names that had a signal on each date, not of the whole universe.\n\n"

      md << "## Known biases (stated, not hidden)\n\n"
      (r[:biases] || []).each { |b| md << "- #{b}\n" }
      md << "\n"
      path = dir.join("#{slug}.md")
      File.write(path, md)
      path
    end

    def wrap_svg(svg)
      # Standalone files need the colour tokens the charts reference.
      tokens = Charts.css_tokens("light", selector: ":root").sub(":root", "svg")
      svg.sub(">") { "><style>#{tokens}</style>" }
    end

    def pct(v)
      v.nil? ? "n/a" : format("%+.1f%%", v.to_f * 100)
    end

    def rate(v)
      v.nil? ? "n/a" : format("%.1f%%", v.to_f * 100)
    end

    def money(v)
      v.nil? ? "n/a" : format("$%.1fbn", v.to_f / 1e9)
    end
  end
end
