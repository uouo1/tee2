# frozen_string_literal: true

require "test_helper"
require "tmpdir"

# Port of tests/test_api.py::ExportTests (the PDF leg of
# test_every_available_format_writes_a_file and test_html_escapes_untrusted_text)
# plus the checks the contract adds for the Prawn writer: a %PDF file, landscape
# A4, one page per slide, vectors for the football field and the charts, the
# sequential ramp on the sensitivity table, and no exception on empty payloads.
class ExportersPdfTest < ActiveSupport::TestCase
  Deck = Struct.new(:title, :slides, :banker, keyword_init: true)
  SlideFixture = Struct.new(:kind, :title, :subtitle, :payload_hash, keyword_init: true)

  CURRENCY = "USD"
  DISCLAIMER = "This document has been prepared for discussion purposes only and does not constitute an offer, " \
               "a recommendation or advice. Financial projections are illustrative."

  FINANCIAL_ROWS = [
    { fiscal_year: 2020, is_estimate: false, revenue: 2173.3, ebitda: 87.0, ebitda_margin: 0.04, ebit: -10.0, net_income: -58.0, eps: -1.44, capex: 46.0 },
    { fiscal_year: 2021, is_estimate: false, revenue: 1981.6, ebitda: 5.0, ebitda_margin: nil, ebit: -79.0, net_income: -81.0, eps: -1.83, capex: 35.0 },
    { fiscal_year: 2022, is_estimate: false, revenue: 1795.6, ebitda: 59.0, ebitda_margin: 0.033, ebit: -7.0, net_income: -10.0, eps: -0.22, capex: 20.0 },
    { fiscal_year: 2023, is_estimate: false, revenue: 2173.6, ebitda: 185.0, ebitda_margin: 0.0849, ebit: 129.0, net_income: 97.0, eps: 2.11, capex: 27.0 },
    { fiscal_year: 2024, is_estimate: false, revenue: 2440.8, ebitda: 320.0, ebitda_margin: 0.1313, ebit: 264.0, net_income: 239.0, eps: 5.18, capex: 31.0 },
    { fiscal_year: 2025, is_estimate: true, revenue: 2367.2, ebitda: 363.0, ebitda_margin: 0.1532, ebit: 313.0, net_income: 301.0, eps: 6.50, capex: 23.0 }
  ].freeze

  RANGES = [
    { method: "Trading comps — EV/EBITDA", low: 115.28, high: 176.39, mid: 145.8, basis: "9.5x–14.5x FY2025 EBITDA" },
    { method: "Trading comps — EV/Revenue", low: 153.73, high: 221.30, mid: 187.5, basis: "1.4x–2.1x" },
    { method: "DCF", low: 72.88, high: 115.14, mid: 94.0, basis: "WACC 8.5%–10.5%" },
    { method: "52-week trading range", low: 77.77, high: 142.00, mid: 109.9, basis: "Low–high" }
  ].freeze

  STATS = {
    ev_revenue: { count: 3, min: 1.2, p25: 1.5, median: 1.8, p75: 2.2, max: 2.6, mean: 1.9 },
    ev_ebitda: { count: 3, min: 9.1, p25: 10.4, median: 11.8, p75: 13.0, max: 14.2, mean: 11.7 },
    pe: { count: 3, min: 18.0, p25: 21.0, median: 24.5, p75: 27.0, max: 30.1, mean: 24.1 },
    premium_1day: { count: 2, min: 0.22, p25: 0.25, median: 0.28, p75: 0.31, max: 0.34, mean: 0.28 }
  }.freeze

  SENSITIVITY_GRID = [
    [96.14, 85.83, 77.45, 70.51, 64.66],
    [104.73, 92.70, 83.10, 75.27, 68.74],
    [114.95, 100.70, 89.58, 80.65, nil],
    [127.33, 110.19, 97.17, 86.90, 78.70],
    [142.63, 121.60, 106.06, 94.01, 84.42]
  ].freeze

  # One slide per kind in Pitchbooks::SLIDE_ORDER with the payload keys the
  # Python builders emit (argos/pitchbook.py `_slide_*`).
  def self.fixture_slides
    [
      SlideFixture.new(
        kind: "cover", title: "Project Meter", subtitle: "Strategic alternatives for Northvale Grid Software",
        payload_hash: { client_name: "Board of Northvale Grid", target: "Northvale Grid Software", ticker: "NVG",
                        banker: "Argos Advisory", date: "13 October 2026", confidential: true }
      ),
      SlideFixture.new(kind: "disclaimer", title: "Disclaimer", subtitle: nil, payload_hash: { body: DISCLAIMER }),
      SlideFixture.new(
        kind: "executive_summary", title: "Executive summary", subtitle: "Northvale Grid Software — situation assessment",
        payload_hash: {
          bullets: [
            { text: "Northvale Grid Software (NVG) trades at $85.57 per share, a market capitalisation of $3.7bn and an enterprise value of $4.0bn, or 11.0x FY2025 EBITDA." },
            { text: "Our analysis supports a reference range of $96.53–$159.19 per share, versus the current $85.57, implying 86.0% upside at the top of the range." },
            { text: "Backlog at quarter end was $4.4 billion compared with $4.5 billion in the prior year.",
              source: { document_id: 2, title: "Northvale Q2 earnings release", published_at: "2026-07-28", doc_type: "press-release" } },
            { text: "Recurring themes in the company's own disclosure on these topics: bookings, backlog, pricing & renewals." },
            # The true minus sign (U+2212) is outside Windows-1252, which the built-in font is limited to.
            { text: "Corpus tone across 7 documents is neutral (+0.03 on a −1 to +1 scale), which we read as neither a tailwind nor a headwind for a process narrative." }
          ],
          reference_range: { low: 96.53, high: 159.19 }, share_price: 85.57, currency: CURRENCY
        }
      ),
      SlideFixture.new(
        kind: "company_overview", title: "Northvale Grid Software — company overview", subtitle: "Grid software · Portland, OR",
        payload_hash: {
          description: "Northvale sells metering and grid-edge analytics software to utilities; recurring platform revenue is 61% of the mix.",
          kpis: [
            { label: "Share price", value: "$85.57" }, { label: "Market capitalisation", value: "$3.7bn" },
            { label: "Enterprise value", value: "$4.0bn" }, { label: "Net debt", value: "$312.0m" },
            { label: "FY2025 revenue", value: "$2.4bn" }, { label: "FY2025 EBITDA", value: "$363.0m (15.3%)" },
            { label: "EV / EBITDA", value: "11.0x" }, { label: "Employees", value: "5,400" }
          ],
          extracted_kpis: [
            { label: "Gross margin", value: "29.9%", observations: 24, unit: "%" },
            { label: "Backlog / RPO", value: "4400.0", observations: 5, unit: "USDm" },
            { label: "ARR", value: "417.0", observations: 1, unit: "USDm" }
          ],
          sector: "Grid software", country: "US"
        }
      ),
      SlideFixture.new(
        kind: "market_overview", title: "Grid software — market overview", subtitle: "What the corpus says is changing",
        payload_hash: {
          narrative: "Across 41 documents published in the last 180 days, sector discussion has concentrated on pricing, backlog, demand response.",
          themes: (1..10).map { |i| { theme: "theme #{i}", mentions: 20 - i, prior_mentions: 10 - (i / 2), lift: (2.5 - i * 0.1).round(2), rank: 3.0 - i * 0.2 } },
          sentiment_timeline: %w[2025-10 2025-11 2026-01 2026-02 2026-04 2026-05 2026-07 2026-08 2026-10].each_with_index.map do |month, i|
            { month: month, sentiment: [0.2904, 0.1313, 0.5516, 0.0422, nil, 0.2815, 0.0729, 0.2051, 0.2032][i], documents: 3 + i }
          end,
          volume_by_type: { months: %w[2026-08 2026-09 2026-10], series: [{ name: "filing", values: [2, 1, 3] }] }
        }
      ),
      SlideFixture.new(
        kind: "financial_performance", title: "Northvale Grid Software — financial performance",
        subtitle: "USDm, fiscal years; forward years are estimates",
        payload_hash: { rows: FINANCIAL_ROWS, growths: [-0.0882, -0.0939, 0.2105, 0.1229, -0.0302], revenue_cagr: 0.0172, currency: CURRENCY,
                        note: "Revenue compounds at 1.7% across the period with EBITDA margin moving from 4.0% to 15.3%." }
      ),
      SlideFixture.new(
        kind: "valuation_summary", title: "Valuation summary", subtitle: "Implied value per share, USD",
        payload_hash: { ranges: RANGES, reference_price: 85.57, concluded_range: { low: 96.53, high: 159.19 },
                        axis: { min: 60.0, max: 240.0 }, currency: CURRENCY }
      ),
      SlideFixture.new(
        kind: "trading_comps", title: "Trading comparables", subtitle: "Grid software · USDm except per-share and multiples",
        payload_hash: {
          target: { ticker: "NVG", name: "Northvale Grid Software", is_target: true, share_price: 85.57, market_cap: 3710.0,
                    enterprise_value: 4022.0, net_debt: 312.0, revenue: 2367.2, ebitda: 363.0, ebitda_margin: 0.1532,
                    ev_revenue: 1.7, ev_ebitda: 11.08, pe: 13.2, fiscal_year: 2025 },
          rows: [
            { ticker: "HLDX", name: "Helix Data", share_price: 42.10, market_cap: 5100.0, enterprise_value: 5600.0, revenue: 2150.0,
              ebitda_margin: 0.21, ev_revenue: 2.6, ev_ebitda: 12.4, pe: 30.1 },
            { ticker: "SNTR", name: "Sentra Meters", share_price: 18.75, market_cap: 1900.0, enterprise_value: 2300.0, revenue: 1900.0,
              ebitda_margin: 0.12, ev_revenue: 1.2, ev_ebitda: 9.1, pe: 18.0 },
            { ticker: "QNTM", name: "Quantum Flow", share_price: 101.00, market_cap: 8100.0, enterprise_value: 8400.0, revenue: 4700.0,
              ebitda_margin: nil, ev_revenue: 1.8, ev_ebitda: nil, pe: 24.5 }
          ],
          stats: STATS, labels: { ev_revenue: "EV / Revenue", ev_ebitda: "EV / EBITDA", pe: "P / E" }, currency: CURRENCY
        }
      ),
      SlideFixture.new(
        kind: "precedent_transactions", title: "Precedent transactions", subtitle: "Announced transactions in the sector",
        payload_hash: {
          rows: [
            { announced_on: "2025-03-14", target: "Meterline", acquirer: "GridCo", ev: 1850.0, ev_revenue: 2.9, ev_ebitda: 13.5, premium_1day: 0.34, consideration: "Cash" },
            { announced_on: "2024-11-02", target: "VoltIQ", acquirer: "Ampere Partners", ev: 920.0, ev_revenue: 2.1, ev_ebitda: nil, premium_1day: 0.22, consideration: "Cash & stock" }
          ],
          stats: STATS, note: "Median EV/EBITDA of 13.5x on a median one-day premium of 28.0% across 2 transactions."
        }
      ),
      SlideFixture.new(
        kind: "dcf", title: "Discounted cash flow analysis", subtitle: "WACC 9.50% · perpetuity growth · mid-year discounting",
        payload_hash: {
          projections: (0..4).map do |i|
            { year: 2026 + i, revenue: 2460.0 * (1.04**i), growth: 0.04, ebitda: 380.0 * (1.05**i), ebit: 330.0 * (1.05**i),
              taxes: 76.0 * (1.05**i), capex: 48.0, fcf: 250.8 + 14.9 * i, pv_fcf: (250.8 + 14.9 * i) / (1.095**(i + 0.5)) }
          end,
          assumptions: { wacc: 0.095, terminal_growth: 0.02, years: 5, mid_year_convention: true },
          pv_explicit: 1061.0, pv_terminal: 2933.0, terminal_share_of_ev: 0.734, enterprise_value: 3994.0, equity_value: 3682.0,
          value_per_share: 84.09, share_price: 85.57, currency: CURRENCY,
          note: "Base case equity value of $3.7bn equates to 84.09 per share; the terminal value accounts for 73.4% of enterprise value."
        }
      ),
      SlideFixture.new(
        kind: "dcf_sensitivity", title: "DCF sensitivity", subtitle: "Implied value per share across WACC and terminal growth",
        payload_hash: { wacc_axis: [0.08, 0.0875, 0.095, 0.1025, 0.11], terminal_axis: [0.015, 0.02, 0.025, 0.03, 0.035],
                        grid: SENSITIVITY_GRID, min: 64.66, max: 142.63, reference_price: 85.57, currency: CURRENCY }
      ),
      SlideFixture.new(
        kind: "buyers", title: "Potential counterparties", subtitle: "Indicative, based on scale, multiple and disclosure tone",
        payload_hash: {
          candidates: [
            { name: "Quantum Flow", ticker: "QNTM", type: "Strategic", enterprise_value: 8400.0, relative_size: 2.09, sentiment: 0.12,
              rationale: "balance-sheet capacity to absorb the target; trades at a premium multiple, so stock is attractive currency" },
            { name: "Helix Data", ticker: "HLDX", type: "Strategic", enterprise_value: 5600.0, relative_size: 1.39, sentiment: 0.05,
              rationale: "balance-sheet capacity to absorb the target; accretive margin profile supports a cash offer" },
            { name: "Financial sponsors", ticker: "—", type: "Sponsor", enterprise_value: nil, relative_size: nil, sentiment: nil,
              rationale: "Recurring revenue supports leverage; precedent deals cleared at a median 28.0% premium" }
          ],
          target_enterprise_value: 4022.0
        }
      ),
      SlideFixture.new(
        kind: "process", title: "Process considerations and next steps", subtitle: nil,
        payload_hash: { bullets: [
          "Reference range of $96.53–$159.19 per share implies a +13% to +86% move versus the current $85.57.",
          "Precedent one-day premia have clustered between 25.0% and 31.0%.",
          "Suggested next steps: agree the comp set and base-case assumptions, confirm the counterparty list."
        ] }
      ),
      SlideFixture.new(
        kind: "evidence_appendix", title: "Appendix — sources and evidence", subtitle: "2 pinned item(s) from the research corpus",
        payload_hash: { items: [
          { id: 1, quote: "Backlog at quarter end was $4.4 billion.", note: nil, created_at: "2026-10-13T02:00:00Z", slide_id: 3, document_id: 2,
            title: "Northvale Q2 earnings release", doc_type: "press-release", published_at: "2026-07-28", source: "EDGAR", ticker: "NVG" },
          { id: 2, quote: "We expect pricing discipline to hold through renewals & <renegotiations>.", note: "margin", created_at: "2026-10-13T02:01:00Z",
            slide_id: nil, document_id: 5, title: "Q2 call transcript", doc_type: "transcript", published_at: "2026-07-29", source: "EDGAR", ticker: "NVG" }
        ] }
      )
    ]
  end

  FIXTURE_SLIDES = fixture_slides.freeze
  KINDS = FIXTURE_SLIDES.map(&:kind).freeze

  # Prawn sets colours as "r g b scn" (fill) / "r g b SCN" (stroke) in the
  # DeviceRGB space, each channel on [0, 1] rounded the way PDF::Core does.
  def rgb_operator(hex, operator = "scn")
    channels = hex.delete_prefix("#").scan(/../).map { |pair| pair.to_i(16) / 255.0 }
    "#{channels.map { |c| PDF::Core.real(c) }.join(' ')} #{operator}"
  end

  # Prawn emits text as hex strings inside TJ arrays (kerning splits a line
  # into runs), so decode every text object back to a string for assertions.
  def text_of(rendered)
    rendered.scan(/BT\n(.*?)\nET/m).map do |(block)|
      block.scan(/<([0-9a-f]+)>/i).map { |(hex)| [hex].pack("H*") }.join.force_encoding("Windows-1252").encode("UTF-8")
    end.join("\n")
  end

  def page_count(rendered) = rendered.scan(%r{/Type /Page\b}).size

  setup do
    @deck = Deck.new(title: "Project Meter", slides: FIXTURE_SLIDES, banker: "Argos Advisory")
    @dir = Dir.mktmpdir("argos-pdf")
  end

  teardown { FileUtils.remove_entry(@dir) if @dir && File.exist?(@dir) }

  # ---------------------------------------------------- file (ExportTests)

  test "write creates parent directories, returns a Pathname and writes a PDF of real size" do
    path = Exporters::Pdf.write(@deck, File.join(@dir, "nested", "deck.pdf"))
    assert_kind_of Pathname, path
    assert_predicate path, :file?
    # test_every_available_format_writes_a_file: > 1000 bytes.
    assert_operator path.size, :>, 1000
    assert path.binread.start_with?("%PDF"), "file does not start with %PDF"
  end

  test "landscape A4 pages with the reportlab margins" do
    pdf = Exporters::Pdf.build(@deck)
    width, height = pdf.page.dimensions[2..3]
    assert_in_delta 841.89, width, 0.01
    assert_in_delta 595.28, height, 0.01
    assert_in_delta 841.89 - 30 * Exporters::Pdf::MM, pdf.bounds.width, 0.01
    assert_includes pdf.render, "/MediaBox [0 0 841.89 595.28]"
  end

  test "document metadata carries the deck title and the banker as author" do
    rendered = Exporters::Pdf.build(@deck).render
    utf16 = ->(s) { "<feff#{s.encode('UTF-16BE').unpack1('H*')}>" }
    assert_includes rendered, "/Title #{utf16.call('Project Meter')}"
    assert_includes rendered, "/Author #{utf16.call('Argos Advisory')}"
    # A deck without a banker (or one that does not expose it) is authored by Argos.
    bare = Struct.new(:title, :slides).new("Bare", FIXTURE_SLIDES.first(1))
    assert_includes Exporters::Pdf.build(bare).render, "/Author #{utf16.call('Argos')}"
  end

  # ---------------------------------------------------------- pagination

  test "one page per slide for every slide kind" do
    pdf = Exporters::Pdf.build(@deck)
    assert_equal FIXTURE_SLIDES.size, pdf.page_count
    rendered = pdf.render
    assert_equal FIXTURE_SLIDES.size, page_count(rendered)
    # The /Pages node is not a page.
    assert_equal 1, rendered.scan(%r{/Type /Pages\b}).size
  end

  test "each kind renders one page on its own" do
    FIXTURE_SLIDES.each do |slide|
      deck = Deck.new(title: "One", slides: [slide])
      assert_equal 1, Exporters::Pdf.build(deck).page_count, slide.kind
    end
  end

  # ------------------------------------------------------- empty payloads

  test "no exception and still one page per slide when the payloads are empty" do
    slides = KINDS.map { |kind| SlideFixture.new(kind: kind, title: kind.humanize, subtitle: nil, payload_hash: {}) }
    pdf = Exporters::Pdf.build(Deck.new(title: "Empty", slides: slides))
    assert_equal slides.size, pdf.page_count
    assert pdf.render.start_with?("%PDF")

    # Even a slide with no title, no subtitle and a nil payload renders.
    blank = KINDS.map { |kind| SlideFixture.new(kind: kind, title: nil, subtitle: nil, payload_hash: nil) }
    assert_equal blank.size, Exporters::Pdf.build(Deck.new(title: nil, slides: blank)).page_count
  end

  test "no precedents and no evidence render their notes, not errors" do
    precedents = SlideFixture.new(
      kind: "precedent_transactions", title: "Precedent transactions", subtitle: "Announced transactions in the sector",
      payload_hash: { rows: [], stats: { ev_ebitda: {}, premium_1day: {} },
                      note: "No precedent transactions are loaded for this sector." }
    )
    evidence = SlideFixture.new(kind: "evidence_appendix", title: "Appendix", subtitle: "0 pinned item(s)", payload_hash: { items: [] })
    buyers = SlideFixture.new(kind: "buyers", title: "Potential counterparties", subtitle: nil, payload_hash: { candidates: [] })
    field = SlideFixture.new(kind: "valuation_summary", title: "Valuation summary", subtitle: nil,
                             payload_hash: { ranges: [], reference_price: nil, currency: "USD" })
    comps = SlideFixture.new(kind: "trading_comps", title: "Trading comparables", subtitle: nil,
                             payload_hash: { target: nil, rows: [], stats: {}, currency: "USD" })
    sensitivity = SlideFixture.new(kind: "dcf_sensitivity", title: "DCF sensitivity", subtitle: nil,
                                   payload_hash: { wacc_axis: [], terminal_axis: [], grid: [], reference_price: nil })
    deck = Deck.new(title: "Sparse", slides: [precedents, evidence, buyers, field, comps, sensitivity])
    pdf = Exporters::Pdf.build(deck)
    assert_equal 6, pdf.page_count
    text = text_of(pdf.render)
    assert_includes text, "No precedent transactions"
    assert_includes text, "No evidence pinned yet."
  end

  test "payload text outside Windows-1252 is transliterated rather than raising" do
    slide = SlideFixture.new(kind: "process", title: "Tone → outlook", subtitle: "≥ 3 documents",
                             payload_hash: { bullets: ["Score of −0.4 on a −1 to +1 scale ✓ 日本"] })
    pdf = Exporters::Pdf.build(Deck.new(title: "Unicode", slides: [slide]))
    assert_equal 1, pdf.page_count
    assert_equal "Score of -0.4 on a -1 to +1 scale ? ??", Exporters::Pdf.clean("Score of −0.4 on a −1 to +1 scale ✓ 日本")
    assert_equal "Tone -> outlook", Exporters::Pdf.clean("Tone → outlook")
    # Characters that are in 1252 pass through untouched.
    assert_equal "— – • “q” · € £ …", Exporters::Pdf.clean("— – • “q” · € £ …")
  end

  # ---------------------------------------------------- untrusted text

  test "untrusted text prints literally instead of being parsed as markup" do
    # test_html_escapes_untrusted_text, PDF leg: the inline-format parser must
    # see escaped entities, otherwise "<script>" is swallowed as an unknown tag.
    slide = SlideFixture.new(kind: "process", title: "<script>alert(1)</script>", subtitle: nil,
                             payload_hash: { bullets: ["<img src=x onerror=alert(1)>", "Cash & stock <b>not bold</b>"] })
    pdf = Exporters::Pdf.build(Deck.new(title: "Escaped", slides: [slide]))
    assert_equal 1, pdf.page_count
    text = text_of(pdf.render)
    assert_includes text, "<script>alert(1)</script>"
    assert_includes text, "<img src=x onerror=alert(1)>"
    assert_includes text, "Cash & stock <b>not bold</b>"
    assert_equal "a &amp; b &lt;c&gt;", Exporters::Pdf.esc("a & b <c>")
  end

  # ------------------------------------------------------------- vectors

  test "the football field is drawn with filled rectangles in the series colour and a reference line" do
    slide = FIXTURE_SLIDES.find { |s| s.kind == "valuation_summary" }
    rendered = Exporters::Pdf.build(Deck.new(title: "Field", slides: [slide])).render
    fill = rgb_operator(Charts::PALETTE[:light][:series_1])
    assert_includes rendered, fill
    # One rectangle per range (re ... f) at 88% opacity (an ExtGState with /ca 0.88).
    assert_operator rendered.scan(/ re\nf\n/).size, :>=, RANGES.size
    assert_match(%r{/ca 0\.88}, rendered)
    # Gridlines in the grid colour and the 1.2pt current-price line in ink.
    assert_includes rendered, rgb_operator(Charts::PALETTE[:light][:grid], "SCN")
    assert_includes rendered, rgb_operator(Charts::PALETTE[:light][:text], "SCN")
    assert_includes rendered, "1.2 w"
    text = text_of(rendered)
    assert_includes text, "Current $85.57"
    # Axis ticks and the range labels are whole currency amounts; the table below repeats the ranges to 2dp.
    assert_includes text, "$115"
    assert_includes text, "115.28"
    RANGES.each { |range| assert_includes text, range[:method] }
  end

  test "column charts draw one bar per period and label only the ends" do
    slide = FIXTURE_SLIDES.find { |s| s.kind == "financial_performance" }
    rendered = Exporters::Pdf.build(Deck.new(title: "Columns", slides: [slide])).render
    assert_operator rendered.scan(/ re\nf\n/).size, :>=, FINANCIAL_ROWS.size
    assert_includes rendered, rgb_operator(Charts::PALETTE[:light][:series_1])
    text = text_of(rendered)
    assert_includes text, "FY2020"
    assert_includes text, "FY2025"
    assert_includes text, "Revenue (USDm)"
    assert_includes text, "2,173"     # first bar's value label ({:,.0f})
    assert_includes text, "2,367"     # last bar's value label
    # Years are not grouped ("2020", not the reference's "2,020").
    assert_includes text, "2020"
    refute_includes text, "2,020"

    # The tone chart's values do not recur in its table, so it shows the
    # selective labelling: ends labelled (rebased +1, {:,.2f}), middle bars not.
    slide = FIXTURE_SLIDES.find { |s| s.kind == "market_overview" }
    text = text_of(Exporters::Pdf.build(Deck.new(title: "Tone", slides: [slide])).render)
    assert_includes text, "25-10"     # month[-5:]
    assert_includes text, "26-10"
    assert_includes text, "1.29"
    assert_includes text, "1.20"
    refute_includes text, "1.55"
    # Only the first eight themes make the table.
    assert_includes text, "theme 8"
    refute_includes text, "theme 9"
  end

  test "the sensitivity heatmap tints cells along the sequential ramp" do
    slide = FIXTURE_SLIDES.find { |s| s.kind == "dcf_sensitivity" }
    rendered = Exporters::Pdf.build(Deck.new(title: "Heat", slides: [slide])).render
    seq = Charts::PALETTE[:light][:seq]
    # The minimum lands on the lightest step and the maximum on the darkest.
    assert_includes rendered, rgb_operator(seq.first)
    assert_includes rendered, rgb_operator(seq.last)
    # Dark steps flip the text to white.
    assert_includes rendered, rgb_operator("#ffffff")
    text = text_of(rendered)
    assert_includes text, "n/a"
    assert_includes text, "Terminal growth \\ WACC"
    assert_includes text, "8.00%"
    assert_includes text, "11.00%"
    assert_includes text, "1.50%"
    assert_includes text, "142.63"
    assert_includes text, "current share price $85.57."
  end

  test "the comps target row is highlighted" do
    slide = FIXTURE_SLIDES.find { |s| s.kind == "trading_comps" }
    rendered = Exporters::Pdf.build(Deck.new(title: "Comps", slides: [slide])).render
    assert_includes rendered, rgb_operator(Exporters::Pdf::HIGHLIGHT)
    text = text_of(rendered)
    assert_includes text, "11.1x"       # target EV/EBITDA, {:,.1f}x
    assert_includes text, "15.3%"       # target margin, {:.1%}
    assert_includes text, "n/a"         # QNTM's missing margin and EV/EBITDA
    assert_includes text, "Peer distribution"
    assert_includes text, "EV / Revenue"
    assert_includes text, "24.5x"       # P/E median from stats
  end

  # ---------------------------------------------------------- formatting

  test "fmt reproduces the Python format specs" do
    assert_equal "n/a", Exporters::Pdf.fmt(nil, "{:,.0f}")
    assert_equal "1,850", Exporters::Pdf.fmt(1850.0, "{:,.0f}")
    assert_equal "13.5x", Exporters::Pdf.fmt(13.5, "{:,.1f}x")
    assert_equal "34%", Exporters::Pdf.fmt(0.34, "{:.0%}")
    assert_equal "15.3%", Exporters::Pdf.fmt(0.1532, "{:.1%}")
    assert_equal "2.09x", Exporters::Pdf.fmt(2.09, "{:,.2f}x")
    assert_equal "-1,234.57", Exporters::Pdf.fmt(-1234.567, "{:,.2f}")
    assert_equal "Cash", Exporters::Pdf.fmt("Cash", "{:,.0f}")   # non-numeric -> as given
    assert_equal "2025", Exporters::Pdf.fmt(2025, nil)           # no pattern -> str(value)
    assert_equal "$", Exporters::Pdf.symbol_for("usd")
    assert_equal "€", Exporters::Pdf.symbol_for("EUR")
    assert_equal "$", Exporters::Pdf.symbol_for(nil)
    assert_equal "", Exporters::Pdf.symbol_for("CHF")
  end

  test "palette comes from the light tokens" do
    assert_equal "2A78D6", Exporters::Pdf::SERIES_1
    assert_equal "0B0B0B", Exporters::Pdf::INK
    assert_equal Charts::PALETTE[:light][:seq].map { |s| s.delete_prefix("#").upcase }, Exporters::Pdf::SEQ
  end
end
