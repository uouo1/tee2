# frozen_string_literal: true

require "pathname"

module Exporters
  # Self-contained HTML deck export (port of argos/exporters/html_export.py).
  #
  # One file, no external assets, printable to PDF from a browser. Charts are
  # the same server-side SVG the web UI renders, and the palette tokens are
  # inlined for both colour schemes, so a deck mailed to a colleague looks right
  # on their machine whichever theme they use.
  #
  # The slide markup is the ERB partials under app/views/decks/, rendered
  # through ApplicationController.render, so the in-app preview and the export
  # are the same markup by construction. Every text value is escaped by ERB;
  # only Charts' SVG/table output (which escapes its own labels) is raw.
  module Html
    # The deck stylesheet from the Python STYLE string, verbatim.
    STYLE = <<~CSS
      *, *::before, *::after { box-sizing: border-box; }
      body {
        margin: 0; background: var(--plane); color: var(--text-primary);
        font-family: system-ui, -apple-system, "Segoe UI", sans-serif; font-size: 15px; line-height: 1.5;
      }
      .deck { max-width: 1060px; margin: 0 auto; padding: 32px 16px 64px; }
      .slide {
        background: var(--surface-1); border: 1px solid var(--border); border-radius: 10px;
        padding: 28px 30px 30px; margin-bottom: 22px; page-break-after: always; break-after: page;
      }
      .slide:last-child { page-break-after: auto; }
      .slide-no { font-size: 11px; letter-spacing: 0.08em; text-transform: uppercase; color: var(--muted); }
      h1 { font-size: 30px; margin: 10px 0 6px; line-height: 1.2; }
      h2 { font-size: 21px; margin: 6px 0 4px; line-height: 1.25; }
      .sub { color: var(--text-secondary); font-size: 13.5px; margin: 0 0 18px; }
      .cover { min-height: 420px; display: flex; flex-direction: column; justify-content: center; }
      .cover .meta { color: var(--text-secondary); font-size: 14px; margin-top: 24px; }
      .badge {
        display: inline-block; font-size: 10.5px; letter-spacing: 0.1em; text-transform: uppercase;
        border: 1px solid var(--border); border-radius: 999px; padding: 3px 10px; color: var(--text-secondary);
      }
      ul.bullets { margin: 0; padding-left: 20px; }
      ul.bullets li { margin-bottom: 11px; }
      .cite { display: block; font-size: 11.5px; color: var(--muted); margin-top: 3px; }
      .grid { display: grid; gap: 18px; }
      .grid.two { grid-template-columns: 1fr 1fr; }
      .grid.kpis { grid-template-columns: repeat(4, 1fr); gap: 12px; }
      .kpi { border: 1px solid var(--border); border-radius: 8px; padding: 10px 12px; }
      .kpi .label { font-size: 11px; color: var(--muted); text-transform: uppercase; letter-spacing: 0.05em; }
      .kpi .value { font-size: 19px; margin-top: 3px; }
      table { border-collapse: collapse; width: 100%; font-size: 12.5px; }
      caption.viz-caption { caption-side: top; text-align: left; font-size: 11.5px; color: var(--muted); padding-bottom: 6px; }
      th, td { padding: 6px 8px; border-bottom: 1px solid var(--grid); text-align: left; }
      th { color: var(--text-secondary); font-weight: 600; font-size: 11.5px; }
      td.num, th.num { text-align: right; font-variant-numeric: tabular-nums; }
      tbody tr.is-highlight { background: color-mix(in srgb, var(--series-1) 12%, transparent); font-weight: 600; }
      tfoot td { border-top: 1px solid var(--axis); border-bottom: none; color: var(--text-secondary); }
      .heatmap td { text-align: center; font-variant-numeric: tabular-nums; border: 2px solid var(--surface-1); }
      .heat-1 { background: var(--seq-1); color: #0b0b0b; } .heat-2 { background: var(--seq-2); color: #0b0b0b; }
      .heat-3 { background: var(--seq-3); color: #0b0b0b; } .heat-4 { background: var(--seq-4); color: #fff; }
      .heat-5 { background: var(--seq-5); color: #fff; } .heat-6 { background: var(--seq-6); color: #fff; }
      .heat-7 { background: var(--seq-7); color: #fff; }
      .heat-ref { outline: 2px solid var(--text-primary); outline-offset: -2px; }
      .note { font-size: 12.5px; color: var(--text-secondary); margin-top: 14px; }
      .quote { border-left: 3px solid var(--series-1); padding: 4px 0 4px 12px; margin: 0 0 14px; font-size: 13px; }
      .quote .src { display: block; color: var(--muted); font-size: 11.5px; margin-top: 4px; }
      .pill { font-size: 11px; color: var(--text-secondary); border: 1px solid var(--border); border-radius: 999px; padding: 2px 8px; margin-right: 6px; display: inline-block; }
      .disclaimer { font-size: 12.5px; color: var(--text-secondary); }
      @media print {
        body { background: #fff; }
        .deck { max-width: none; padding: 0; }
        .slide { border: none; border-radius: 0; margin: 0; padding: 24px; min-height: 96vh; }
      }
      @media (max-width: 760px) {
        .deck { padding: 16px; }
        .grid.two, .grid.kpis { grid-template-columns: 1fr; }
        h1 { font-size: 24px; }
      }
    CSS

    # Additions for the payload keys the port adds (stamp, footnotes, the
    # excluded/reference football-field rows, the table scroller).
    STYLE_ADDITIONS = <<~CSS
      .stamp { font-size: 11.5px; color: var(--muted); font-variant-numeric: tabular-nums; margin-top: 18px; }
      .footnote { font-size: 11.5px; color: var(--muted); margin: 8px 0 0; }
      .table-scroll { overflow-x: auto; }
      tr.is-excluded td, tr.is-reference td { color: var(--muted); }
      tr.is-terminal td { border-top: 1px solid var(--axis); font-weight: 600; }
    CSS

    module_function

    # A complete, self-contained HTML document for a deck.
    def render(deck)
      ApplicationController.render(
        template: "decks/export", layout: false, formats: [:html],
        locals: { deck: deck, body: render_body(deck) }
      )
    end

    # Just the slide markup (<section class="slide">…), for the in-app preview.
    #
    # The web UI embeds this instead of re-implementing fourteen slide layouts,
    # which keeps the on-screen deck and the exported deck identical.
    def render_body(deck)
      ApplicationController.render(partial: "decks/deck", formats: [:html], locals: { deck: deck })
    end

    def write(deck, path)
      path = Pathname(path)
      path.dirname.mkpath
      path.write(render(deck), encoding: "utf-8")
      path
    end

    # Light tokens on :root, dark under the media query unless the page forces
    # light, and dark again when the page forces dark.
    def token_css
      dark_vars = Charts.css_tokens("dark", selector: "X")[/\{\n(.*)\n\}/m, 1]
      <<~CSS
        #{Charts.css_tokens('light', selector: ':root')}
        @media (prefers-color-scheme: dark) {
          :root:where(:not([data-theme="light"])) {
        #{dark_vars}
          }
        }
        :root[data-theme="dark"] {
        #{dark_vars}
        }
      CSS
    end
  end
end
