# frozen_string_literal: true

require "test_helper"
require "nokogiri"
require "open3"
require "tmpdir"
require "zip"

# Port of tests/test_api.py::ExportTests.test_pptx_has_one_slide_per_payload_with_native_charts
# plus the structural checks the contract adds for the OOXML writer: one slide
# part per slide, chart parts for the chart slides, every part well-formed,
# content types and relationships consistent, and python-pptx (verification
# only) able to open the deck and count slides and charts.
#
# XML is parsed with Nokogiri in strict mode (REXML is a bundled gem that is
# not in the Gemfile.lock, so it cannot be required under Bundler).
class ExportersPptxTest < ActiveSupport::TestCase
  Deck = Struct.new(:title, :slides, keyword_init: true)
  SlideFixture = Struct.new(:kind, :title, :subtitle, :payload_hash, keyword_init: true)

  NS = {
    "a" => "http://schemas.openxmlformats.org/drawingml/2006/main",
    "p" => "http://schemas.openxmlformats.org/presentationml/2006/main",
    "c" => "http://schemas.openxmlformats.org/drawingml/2006/chart",
    "r" => "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
  }.freeze

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
  # Slide numbers (1-based) that carry native charts, and how many each has.
  CHART_SLIDES = { 5 => 1, 6 => 2, 7 => 1, 10 => 1 }.freeze

  setup do
    @deck = Deck.new(title: "Project Meter", slides: FIXTURE_SLIDES)
    @dir = Dir.mktmpdir("argos-pptx")
    @path = Exporters::Pptx.write(@deck, File.join(@dir, "nested", "deck.pptx"))
    @entries = read_zip(@path)
  end

  teardown { FileUtils.remove_entry(@dir) if @dir && File.exist?(@dir) }

  # ------------------------------------------------------------ package

  test "write creates parent directories and returns a Pathname" do
    assert_kind_of Pathname, @path
    assert_predicate @path, :file?
    assert_operator @path.size, :>, 10_000
  end

  test "zip holds the content types, presentation, one slide part per slide and chart parts for the chart slides" do
    assert_includes @entries.keys, "[Content_Types].xml"
    assert_includes @entries.keys, "ppt/presentation.xml"
    FIXTURE_SLIDES.each_index do |index|
      assert_includes @entries.keys, "ppt/slides/slide#{index + 1}.xml"
      assert_includes @entries.keys, "ppt/slides/_rels/slide#{index + 1}.xml.rels"
    end
    refute_includes @entries.keys, "ppt/slides/slide#{FIXTURE_SLIDES.size + 1}.xml"
    total_charts = CHART_SLIDES.values.sum
    (1..total_charts).each do |n|
      assert_includes @entries.keys, "ppt/charts/chart#{n}.xml"
      assert_includes @entries.keys, "ppt/charts/_rels/chart#{n}.xml.rels"
      assert_includes @entries.keys, "ppt/embeddings/Microsoft_Excel_Sheet#{n}.xlsx"
    end
    refute_includes @entries.keys, "ppt/charts/chart#{total_charts + 1}.xml"
  end

  test "every XML part, including the embedded workbooks, parses strictly" do
    xml_parts = @entries.select { |name, _| name.end_with?(".xml", ".rels") }
    assert_operator xml_parts.size, :>=, 14 * 2 + 5 * 2 + 10
    xml_parts.each do |name, bytes|
      doc = parse_xml(bytes)
      assert doc.root, "#{name} has no root element"
    end
    @entries.select { |name, _| name.end_with?(".xlsx") }.each do |name, bytes|
      inner = read_zip_bytes(bytes)
      assert_includes inner.keys, "xl/worksheets/sheet1.xml", "#{name} lacks a worksheet"
      inner.each { |inner_name, inner_bytes| assert parse_xml(inner_bytes).root, "#{name}/#{inner_name} malformed" }
    end
  end

  test "content types override every slide, chart and fixed part and declare the workbook extension" do
    types = parse_xml(@entries["[Content_Types].xml"])
    overrides = types.xpath("//*[local-name()='Override']").to_h { |e| [e["PartName"], e["ContentType"]] }
    defaults = types.xpath("//*[local-name()='Default']").to_h { |e| [e["Extension"], e["ContentType"]] }
    assert_equal "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", defaults["xlsx"]
    assert_equal "application/vnd.openxmlformats-package.relationships+xml", defaults["rels"]
    assert_equal "application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml", overrides["/ppt/presentation.xml"]
    @entries.each_key do |name|
      next unless name.start_with?("ppt/slides/slide", "ppt/charts/chart", "ppt/slideMasters/slideMaster", "ppt/slideLayouts/slideLayout", "ppt/theme/")
      next if name.include?("/_rels/")

      assert overrides.key?("/#{name}"), "no content type override for #{name}"
    end
    assert_match(/slide\+xml\z/, overrides["/ppt/slides/slide1.xml"])
    assert_match(/chart\+xml\z/, overrides["/ppt/charts/chart1.xml"])
  end

  test "presentation lists every slide in order, is widescreen and resolves every relationship" do
    presentation = parse_xml(@entries["ppt/presentation.xml"])
    size = presentation.at_xpath("//p:sldSz", NS)
    assert_equal "12191695", size["cx"] # Inches(13.333), truncated like python-pptx
    assert_equal "6858000", size["cy"]  # Inches(7.5)

    rels = relationships(@entries["ppt/_rels/presentation.xml.rels"])
    slide_ids = presentation.xpath("//p:sldId", NS)
    assert_equal FIXTURE_SLIDES.size, slide_ids.size
    slide_ids.each_with_index do |node, index|
      assert_equal "slides/slide#{index + 1}.xml", rels.fetch(node["r:id"])[:target]
      assert_operator node["id"].to_i, :>=, 256
    end
    master_rid = presentation.at_xpath("//p:sldMasterId", NS)["r:id"]
    assert_equal "slideMasters/slideMaster1.xml", rels.fetch(master_rid)[:target]
    assert_includes @entries.keys, "ppt/slideMasters/slideMaster1.xml"
    assert_includes @entries.keys, "ppt/slideLayouts/slideLayout1.xml"
    assert_includes @entries.keys, "ppt/theme/theme1.xml"

    # Each slide relates to the blank layout, and its chart frames to chart parts that exist.
    FIXTURE_SLIDES.each_index do |index|
      slide_rels = relationships(@entries["ppt/slides/_rels/slide#{index + 1}.xml.rels"])
      assert_equal "../slideLayouts/slideLayout1.xml", slide_rels.fetch("rId1")[:target]
      chart_rels = slide_rels.values.select { |rel| rel[:type].end_with?("/chart") }
      assert_equal CHART_SLIDES.fetch(index + 1, 0), chart_rels.size, "slide #{index + 1} chart count"
      chart_rels.each do |rel|
        assert_includes @entries.keys, rel[:target].sub("../", "ppt/")
      end
      frame_rids = parse_xml(@entries["ppt/slides/slide#{index + 1}.xml"]).xpath("//c:chart", NS).map { |n| n["r:id"] }
      assert_equal chart_rels.size, frame_rids.size
      frame_rids.each { |rid| assert slide_rels.key?(rid), "slide #{index + 1} chart frame #{rid} has no relationship" }
    end
    # Each chart part relates to its embedded workbook.
    (1..CHART_SLIDES.values.sum).each do |n|
      target = relationships(@entries["ppt/charts/_rels/chart#{n}.xml.rels"]).fetch("rId1")[:target]
      assert_equal "../embeddings/Microsoft_Excel_Sheet#{n}.xlsx", target
    end
  end

  # ------------------------------------------------------------- slides

  test "cover slide carries the confidentiality badge, title, subtitle and meta line" do
    texts = texts_of(1)
    assert_equal "CONFIDENTIAL — DISCUSSION MATERIALS", texts.first
    assert_includes texts, "Project Meter"
    assert_includes texts, "Strategic alternatives for Northvale Grid Software"
    assert_includes texts, "Prepared for Board of Northvale Grid · Northvale Grid Software · NVG · Argos Advisory · 13 October 2026"
    xml = @entries["ppt/slides/slide1.xml"]
    assert_includes xml, %(sz="4000" b="1")      # 40pt bold title
    assert_includes xml, %(<a:srgbClr val="898781"/>) # muted badge, from Charts::PALETTE light.muted
    refute_includes xml, "<a:tbl>"
    refute_includes xml, "graphicData uri=\"http://schemas.openxmlformats.org/drawingml/2006/chart\""
  end

  test "headings are a 26pt bold title, a secondary subtitle and a hairline rule in the axis colour" do
    xml = @entries["ppt/slides/slide3.xml"]
    assert_includes xml, %(<a:defRPr sz="2600" b="1"><a:solidFill><a:srgbClr val="0B0B0B"/>)
    assert_includes xml, %(<a:defRPr sz="1250"><a:solidFill><a:srgbClr val="52514E"/>)
    assert_includes xml, %(<a:ext cx="11057839" cy="9525"/>)
    assert_includes xml, %(<a:solidFill><a:srgbClr val="C3C2B7"/></a:solidFill><a:ln><a:noFill/></a:ln>)
    assert_includes xml, %(name="Rectangle 2")
    # The disclaimer has no subtitle, so only one heading paragraph.
    assert_equal ["Disclaimer", "•  #{DISCLAIMER}"], texts_of(2)
  end

  test "text slides bullet every item and cite sources in a muted line under the bullet" do
    texts = texts_of(3)
    assert_equal "Reference range $96.53 – $159.19 per share  ·  current $85.57", texts[2]
    assert_includes texts, "•  Backlog at quarter end was $4.4 billion compared with $4.5 billion in the prior year."
    cite = texts.find { |t| t.start_with?("     Source:") }
    assert_equal "     Source: Northvale Q2 earnings release · press-release · 2026-07-28 [doc 2]", cite
    xml = @entries["ppt/slides/slide3.xml"]
    assert_includes xml, %(<a:spcAft><a:spcPts val="700"/></a:spcAft><a:defRPr sz="1400">)
    assert_includes xml, %(<a:spcAft><a:spcPts val="800"/></a:spcAft><a:defRPr sz="950"><a:solidFill><a:srgbClr val="898781"/>)
    assert_includes xml, %(<a:defRPr sz="1300" b="1"><a:solidFill><a:srgbClr val="2A78D6"/>)
    # The reference-range line does not wrap; the bullets box does.
    assert_includes xml, %(<a:bodyPr wrap="none">)
    assert_includes xml, %(<a:bodyPr wrap="square">)
    # Process slide: plain-string bullets.
    assert_includes texts_of(13), "•  Precedent one-day premia have clustered between 25.0% and 31.0%."
  end

  test "company overview has the description, extracted metrics and a two-column KPI table" do
    texts = texts_of(4)
    assert_includes texts, "Northvale sells metering and grid-edge analytics software to utilities; recurring platform revenue is 61% of the mix."
    assert_includes texts, "Metrics extracted from the corpus"
    assert_includes texts, "•  Gross margin: 29.9% (24 observations)"
    xml = @entries["ppt/slides/slide4.xml"]
    # The leading newline in the Python heading becomes a line break.
    assert_includes xml, %(<a:br/><a:r><a:rPr sz="1100" b="1">)
    table = tables_of(4).first
    assert_equal 8, table.size
    assert_equal ["Share price", "$85.57"], table.first
    assert_equal ["Employees", "5,400"], table.last
    assert_includes xml, %(<a:off x="6675120" y="1325880"/><a:ext cx="4937760" cy="2414016"/>) # Inches(7.3), CONTENT_TOP, 5.4in, 0.33in x 8
  end

  test "market overview has a tone line chart and a themes table capped at eight rows" do
    chart = chart_xml_for(5, 0)
    assert_includes chart, "<c:lineChart>"
    assert_includes chart, "<c:v>Mean tone</c:v>"
    assert_includes chart, "<c:formatCode>0.00</c:formatCode>"
    assert_includes chart, %(<c:ptCount val="9"/>)
    assert_includes chart, "<c:v>2025-10</c:v>"
    table = tables_of(5).first
    assert_equal 9, table.size # header + 8 of the 10 themes
    assert_equal ["Emerging theme", "Recent", "Prior", "Lift"], table.first
    assert_equal ["theme 1", "19", "10", "2.40x"], table[1]
  end

  test "financials slide has a column chart, a line chart with a gap for the missing margin, and a formatted table" do
    revenue = chart_xml_for(6, 0)
    assert_includes revenue, %(<c:barDir val="col"/><c:grouping val="clustered"/>)
    assert_includes revenue, "<c:v>Revenue (USDm)</c:v>"
    assert_includes revenue, %(<c:gapWidth val="60"/>)
    assert_includes revenue, "<c:v>FY2020</c:v>"
    assert_includes revenue, "<c:v>2173.3</c:v>"
    assert_includes revenue, %(<a:solidFill><a:srgbClr val="2A78D6"/></a:solidFill>)
    refute_includes revenue, "<c:legend>"

    margin = chart_xml_for(6, 1)
    assert_includes margin, "<c:lineChart>"
    assert_includes margin, "<c:v>EBITDA margin</c:v>"
    assert_includes margin, "<c:formatCode>0.0%</c:formatCode>"
    assert_includes margin, %(<a:ln w="25400"><a:solidFill><a:srgbClr val="2A78D6"/>)
    # Six categories, but the FY2021 margin is nil: ptCount stays 6 and idx 1 is absent.
    assert_includes margin, %(<c:numCache><c:formatCode>0.0%</c:formatCode><c:ptCount val="6"/><c:pt idx="0"><c:v>0.04</c:v></c:pt><c:pt idx="2">)
    # Axis styling: muted 10pt tick labels, axis line in the axis token, gridlines on the value axis only.
    assert_includes margin, %(<a:defRPr sz="1000"><a:solidFill><a:srgbClr val="898781"/>)
    assert_includes margin, %(<c:spPr><a:ln><a:solidFill><a:srgbClr val="C3C2B7"/>)
    assert_equal 1, margin.scan("<c:majorGridlines>").size
    assert_includes margin, %(<c:valAx><c:axId val="2140495176"/><c:scaling><c:orientation val="minMax"/></c:scaling><c:delete val="0"/><c:axPos val="l"/><c:majorGridlines>)

    table = tables_of(6).first
    assert_equal ["FY", "Revenue", "EBITDA", "Margin", "EBIT", "Net income", "EPS", "Capex"], table.first
    assert_equal ["2020", "2,173", "87", "4.0%", "-10", "-58", "-1.44", "46"], table[1]
    assert_equal "n/a", table[2][3] # nil margin
    xml = @entries["ppt/slides/slide6.xml"]
    assert_includes xml, %(<a:pPr algn="r"><a:defRPr sz="950" b="1"><a:solidFill><a:srgbClr val="52514E"/>) # numeric header
    assert_includes xml, %(<a:pPr algn="r"><a:defRPr sz="950" b="0"><a:solidFill><a:srgbClr val="0B0B0B"/>)  # numeric body cell
    assert_includes xml, %(<a:gridCol w="1382229"/>)
    assert_includes xml, %(<a:gridCol w="1382236"/>) # remainder on the last column, as python-pptx
    assert_includes texts_of(6), "Revenue compounds at 1.7% across the period with EBITDA margin moving from 4.0% to 15.3%."
  end

  test "football field is a stacked bar whose base series is transparent and whose span series is the range" do
    chart = chart_xml_for(7, 0)
    assert_includes chart, %(<c:barDir val="bar"/><c:grouping val="stacked"/>)
    assert_includes chart, %(<c:overlap val="100"/>)
    sers = chart.scan(%r{<c:ser>.*?</c:ser>}m)
    assert_equal 2, sers.size
    base, span = sers
    assert_includes base, "<c:v>Base</c:v>"
    assert_includes base, %(<c:spPr><a:noFill/><a:ln><a:noFill/></a:ln></c:spPr>)
    assert_includes span, "<c:v>Range</c:v>"
    assert_includes span, %(<c:spPr><a:solidFill><a:srgbClr val="2A78D6"/></a:solidFill></c:spPr>)
    # Categories are reversed so the first method in the payload is drawn at the top.
    categories = base.scan(%r{<c:cat>.*?</c:cat>}m).first.scan(%r{<c:v>(.*?)</c:v>}).flatten
    assert_equal RANGES.map { |r| r[:method] }.reverse, categories
    base_values = base.scan(%r{<c:val>.*?</c:val>}m).first.scan(%r{<c:v>(.*?)</c:v>}).flatten.map(&:to_f)
    span_values = span.scan(%r{<c:val>.*?</c:val>}m).first.scan(%r{<c:v>(.*?)</c:v>}).flatten.map(&:to_f)
    assert_equal RANGES.map { |r| r[:low] }.reverse, base_values
    RANGES.reverse.each_with_index { |r, i| assert_in_delta r[:high] - r[:low], span_values[i], 1e-9 }
    assert_includes chart, "<c:formatCode>#,##0.00</c:formatCode>"
    # Category axis on the left, value axis along the bottom for horizontal bars.
    assert_includes chart, %(<c:catAx><c:axId val="-2068027336"/><c:scaling><c:orientation val="minMax"/></c:scaling><c:delete val="0"/><c:axPos val="l"/>)
    assert_includes chart, %(<c:axPos val="b"/><c:majorGridlines>)

    note = texts_of(7).last
    assert note.start_with?("Current share price: $85.57. "), note
    assert_includes note, "Trading comps — EV/EBITDA: $115.28–$176.39; "
    assert_includes note, "52-week trading range: $77.77–$142.00"
    xml = @entries["ppt/slides/slide7.xml"]
    assert_includes xml, %(<a:off x="566928" y="1325880"/><a:ext cx="11057839" cy="3566160"/>) # chart: CONTENT_TOP, 3.9in
    assert_includes xml, %(<a:off x="566928" y="4892040"/>)                                   # note directly under it
  end

  test "trading comps has the comps table with the target in bold and a peer distribution table" do
    tables = tables_of(8)
    assert_equal 2, tables.size
    comps, distribution = tables
    assert_equal "Mkt cap (USDm)", comps.first[3]
    assert_equal ["NVG", "Northvale Grid Software", "85.57", "3,710", "4,022", "2,367", "15.3%", "1.7x", "11.1x", "13.2x"], comps[1]
    assert_equal "n/a", comps[4][6] # missing margin
    xml = @entries["ppt/slides/slide8.xml"]
    first_table = xml[/<a:tbl>.*?<\/a:tbl>/m]
    target_row = first_table.scan(%r{<a:tr h=".*?">.*?</a:tr>}m)[1]
    assert_equal 10, target_row.scan(%(b="1")).size / 2, "target row cells bold (defRPr and rPr)"
    peer_row = first_table.scan(%r{<a:tr h=".*?">.*?</a:tr>}m)[2]
    assert_equal 10, peer_row.scan(%(b="0")).size / 2, "peer row cells not bold"
    assert_equal ["Peer distribution", "Min", "25th", "Median", "75th", "Max"], distribution.first
    assert_equal ["EV / EBITDA", "9.1x", "10.4x", "11.8x", "13.0x", "14.2x"], distribution[2]
    assert_includes xml, %(<a:off x="566928" y="4892040"/>) # second table at Inches(5.35)
  end

  test "precedents slide has the deal table and the note" do
    table = tables_of(9).first
    assert_equal ["Announced", "Target", "Acquirer", "EV (USDm)", "EV/Rev", "EV/EBITDA", "Premium", "Consideration"], table.first
    assert_equal ["2025-03-14", "Meterline", "GridCo", "1,850", "2.9x", "13.5x", "34%", "Cash"], table[1]
    assert_equal "n/a", table[2][5]
    assert_includes texts_of(9), "Median EV/EBITDA of 13.5x on a median one-day premium of 28.0% across 2 transactions."
  end

  test "DCF slide has the UFCF column chart, the value bridge and the projections table" do
    chart = chart_xml_for(10, 0)
    assert_includes chart, "<c:v>Unlevered FCF (USDm)</c:v>"
    assert_includes chart, "<c:v>2026</c:v>"
    assert_includes chart, "<c:v>250.8</c:v>"
    bridge, projections = tables_of(10)
    assert_equal [["PV of forecast FCF", "$1,061m"], ["PV of terminal value", "$2,933m"], ["Enterprise value", "$3,994m"],
                  ["Equity value", "$3,682m"], ["Value per share", "$84.09"], ["Current share price", "$85.57"]], bridge
    assert_equal ["Year", "Revenue", "Growth", "EBITDA", "EBIT", "Taxes", "Capex", "UFCF", "PV"], projections.first
    assert_equal "2026", projections[1][0] # a year, not "2,026"
    assert_equal "4.0%", projections[1][2]
    assert_equal 6, projections.size
    xml = @entries["ppt/slides/slide10.xml"]
    assert_includes xml, %(<a:off x="6400800" y="1325880"/><a:ext cx="5212080" cy="1810512"/>) # bridge: 7.0in, 5.7in wide, 0.33in x 6
    assert_includes texts_of(10), "Base case equity value of $3.7bn equates to 84.09 per share; the terminal value accounts for 73.4% of enterprise value."
  end

  test "sensitivity table shades cells on the sequential ramp and flips to white text on dark steps" do
    table = tables_of(11).first
    assert_equal ["Terminal growth \\ WACC", "8.00%", "8.75%", "9.50%", "10.25%", "11.00%"], table.first
    assert_equal ["1.50%", "96.14", "85.83", "77.45", "70.51", "64.66"], table[1]
    assert_equal "n/a", table[3][5]
    xml = @entries["ppt/slides/slide11.xml"]
    cells = xml.scan(%r{<a:tc>.*?</a:tc>}m)
    seq = Exporters::Pptx::SEQ
    min_cell = cells.find { |c| c.include?("<a:t>64.66</a:t>") }
    max_cell = cells.find { |c| c.include?("<a:t>142.63</a:t>") }
    na_cell = cells.find { |c| c.include?("<a:t>n/a</a:t>") }
    assert_includes min_cell, %(<a:tcPr><a:solidFill><a:srgbClr val="#{seq.first}"/></a:solidFill></a:tcPr>)
    assert_includes min_cell, %(<a:srgbClr val="0B0B0B"/>) # ink on the lightest step
    assert_includes max_cell, %(<a:tcPr><a:solidFill><a:srgbClr val="#{seq.last}"/></a:solidFill></a:tcPr>)
    assert_includes max_cell, %(<a:srgbClr val="FFFFFF"/>) # white on the darkest
    assert_includes na_cell, "<a:tcPr/>"
    assert_equal %w[CDE2FB 9EC5F4 6DA7EC 3987E5 256ABF 184F95 0D366B], seq
    # Mid-ramp: 104.73 -> step int((104.73-64.66)/77.97*6) = 3 -> fourth colour, white text.
    mid_cell = cells.find { |c| c.include?("<a:t>104.73</a:t>") }
    assert_includes mid_cell, %(val="#{seq[3]}")
    assert_includes mid_cell, %(<a:srgbClr val="FFFFFF"/>)
    assert_includes texts_of(11), "Value per share (USD); current share price $85.57."
    assert_includes xml, %(<a:ext cx="11057839" cy="1975104"/>) # 0.36in x 6 rows
  end

  test "buyers slide is a 9pt table of counterparties" do
    table = tables_of(12).first
    assert_equal ["Counterparty", "Type", "EV (USDm)", "EV vs target", "Rationale"], table.first
    assert_equal ["Quantum Flow", "Strategic", "8,400", "2.09x", "balance-sheet capacity to absorb the target; trades at a premium multiple, so stock is attractive currency"], table[1]
    assert_equal ["Financial sponsors", "Sponsor", "n/a", "n/a"], table[3].first(4)
    assert_includes @entries["ppt/slides/slide12.xml"], %(sz="900")
  end

  test "unformatted cells print Python-falsy values as empty, formatted cells only treat nil specially" do
    # `str(row.get(key, "") or "")` in the Python: 0, False and "" are blank cells
    # in a text column, while `_fmt(0)` in a numeric column is still "0".
    slide = SlideFixture.new(kind: "buyers", title: "Buyers", subtitle: nil, payload_hash: { candidates: [
      { name: "", ticker: "X", type: 0, enterprise_value: 0, relative_size: nil, rationale: false },
      { name: "Zero Co", type: "0", enterprise_value: 12.0, relative_size: 0, rationale: [] }
    ] })
    parts = Exporters::Pptx.build(Deck.new(title: "Falsy", slides: [slide])).parts
    rows = tables_in(parts["ppt/slides/slide1.xml"]).first
    assert_equal ["", "", "0", "n/a", ""], rows[1]
    assert_equal ["Zero Co", "0", "12", "0.00x", ""], rows[2] # the string "0" is truthy, as in Python
  end

  test "writes a Pitchbook record: slides come from the association and payloads from the stored JSON" do
    pitchbook = Pitchbook.create!(title: "Project Record", client_name: "Board")
    pitchbook.slides.create!(
      seq: 0, kind: "cover", title: "Project Record", subtitle: "From the database",
      payload: JSON.generate(client_name: "Board", target: "Northvale Grid Software", ticker: "NVG", date: "14 October 2026")
    )
    pitchbook.slides.create!(
      seq: 1, kind: "valuation_summary", title: "Valuation summary", subtitle: "USD",
      payload: JSON.generate(ranges: RANGES.first(2), reference_price: 85.57, currency: CURRENCY)
    )
    pitchbook.slides.create!(seq: 2, kind: "process", title: "Process", payload: JSON.generate(bullets: ["Agree the comp set."]))

    path = Exporters::Pptx.write(Pitchbook.find(pitchbook.id), File.join(@dir, "record.pptx"))
    entries = read_zip(path)
    assert_equal 3, entries.keys.count { |k| k.start_with?("ppt/slides/slide") && k.end_with?(".xml") }
    assert_includes entries["ppt/slides/slide1.xml"], "<a:t>Prepared for Board · Northvale Grid Software · NVG · 14 October 2026</a:t>"
    assert_includes entries["ppt/charts/chart1.xml"], "<c:v>Trading comps — EV/Revenue</c:v>"
    assert_includes entries["ppt/slides/slide3.xml"], "<a:t>•  Agree the comp set.</a:t>"
    assert_includes entries["docProps/core.xml"], "<dc:title>Project Record</dc:title>"
  end

  test "evidence appendix quotes each pinned item with its provenance and escapes markup in quotes" do
    texts = texts_of(14)
    assert_includes texts, "•  “Backlog at quarter end was $4.4 billion.”"
    assert_includes texts, "     Source: NVG · Northvale Q2 earnings release · 2026-07-28 · press-release ·  [doc 2]"
    assert_includes texts, "•  “We expect pricing discipline to hold through renewals & <renegotiations>.”"
    assert_includes @entries["ppt/slides/slide14.xml"], "renewals &amp; &lt;renegotiations&gt;"
  end

  test "an appendix without pinned evidence says so" do
    deck = Deck.new(title: "Empty", slides: [SlideFixture.new(kind: "evidence_appendix", title: "Appendix", subtitle: "0 pinned item(s)", payload_hash: { items: [] })])
    parts = Exporters::Pptx.build(deck).parts
    assert_includes parts["ppt/slides/slide1.xml"], "•  No evidence pinned. Pin passages from the research module to build this appendix."
  end

  test "unknown kinds fall back to the text writer" do
    deck = Deck.new(title: "Odd", slides: [SlideFixture.new(kind: "something_new", title: "New", subtitle: nil, payload_hash: { body: "Just text." })])
    parts = Exporters::Pptx.build(deck).parts
    assert_includes parts["ppt/slides/slide1.xml"], "<a:t>•  Just text.</a:t>"
    assert_equal 1, parts.keys.count { |k| k.start_with?("ppt/slides/slide") && k.end_with?(".xml") }
  end

  test "empty payloads for every kind still produce a well-formed deck" do
    slides = Exporters::Pptx::WRITERS.keys.map { |kind| SlideFixture.new(kind: kind, title: kind.humanize, subtitle: nil, payload_hash: {}) }
    parts = Exporters::Pptx.build(Deck.new(title: "Bare", slides: slides)).parts
    parts.select { |name, _| name.end_with?(".xml", ".rels") }.each do |name, xml|
      assert parse_xml(xml).root, "#{name} malformed"
    end
    assert_equal slides.size, parts.keys.count { |k| k.start_with?("ppt/slides/slide") && k.end_with?(".xml") }
    # Financials, valuation, DCF and market overview still emit their charts (market
    # overview only when it has a timeline), each with an empty but valid cache.
    assert_equal 4, parts.keys.count { |k| k.start_with?("ppt/charts/chart") && k.end_with?(".xml") }
    assert_includes parts["ppt/charts/chart1.xml"], %(<c:ptCount val="0"/>)
  end

  test "text is escaped and control characters are encoded the way python-pptx does" do
    slide = SlideFixture.new(kind: "disclaimer", title: "R&D <beta>", subtitle: "tab\there", payload_hash: { body: "bell\u0007 and \"quotes\"" })
    xml = Exporters::Pptx.build(Deck.new(title: "Esc & co", slides: [slide])).parts["ppt/slides/slide1.xml"]
    assert_includes xml, "<a:t>R&amp;D &lt;beta&gt;</a:t>"
    assert_includes xml, "<a:t>•  bell_x0007_ and \"quotes\"</a:t>"
    doc = parse_xml(xml)
    assert_equal "R&D <beta>", doc.at_xpath("//a:t", NS).text
  end

  # ------------------------------------------------------------ helpers

  test "fmt mirrors Python's _fmt and format specs" do
    assert_equal "n/a", Exporters::Pptx.fmt(nil)
    assert_equal "1,235", Exporters::Pptx.fmt(1234.56)
    assert_equal "1,234.56", Exporters::Pptx.fmt(1234.56, "{:,.2f}")
    assert_equal "-1,234,567.89", Exporters::Pptx.fmt(-1_234_567.891, "{:,.2f}")
    assert_equal "15.3%", Exporters::Pptx.fmt(0.1532, "{:.1%}")
    assert_equal "34%", Exporters::Pptx.fmt(0.34, "{:.0%}")
    assert_equal "11.1x", Exporters::Pptx.fmt(11.08, "{:,.1f}x")
    assert_equal "2.40x", Exporters::Pptx.fmt(2.4, "{:,.2f}x")
    assert_equal "2026", Exporters::Pptx.fmt(2026, "{:.0f}")
    assert_equal "2024-11-02", Exporters::Pptx.fmt("2024-11-02", "{:,.0f}") # non-numeric passes through
    assert_equal "42", Exporters::Pptx.fmt("42", "{:,.0f}")
    assert_raises(ArgumentError) { Exporters::Pptx.fmt(1, "{:>10}") }
  end

  test "currency symbols default to USD and fall back to nothing" do
    assert_equal "$", Exporters::Pptx.symbol_for(nil)
    assert_equal "$", Exporters::Pptx.symbol_for("usd")
    assert_equal "€", Exporters::Pptx.symbol_for("EUR")
    assert_equal "£", Exporters::Pptx.symbol_for("GBP")
    assert_equal "", Exporters::Pptx.symbol_for("CHF")
  end

  test "geometry matches python-pptx's truncating Inches()" do
    assert_equal 12_191_695, Exporters::Pptx::SLIDE_W
    assert_equal 6_858_000, Exporters::Pptx::SLIDE_H
    assert_equal 566_928, Exporters::Pptx::MARGIN
    assert_equal 1_325_880, Exporters::Pptx::CONTENT_TOP
    assert_equal 11_057_839, Exporters::Pptx::CONTENT_W
    assert_equal 5_074_920, Exporters::Pptx::CONTENT_H
    assert_equal "2A78D6", Exporters::Pptx::SERIES_1
    assert_equal "0B0B0B", Exporters::Pptx::INK
  end

  # --------------------------------------------------- python-pptx check

  test "python-pptx opens the deck and reads back the expected slides, charts, series and tables" do
    # Verification only (the contract forbids Python at runtime): a second,
    # independent OOXML reader must open the file, and reading the chart caches
    # and the embedded workbooks back is what a renderer does before it draws.
    script = <<~PY
      from pptx import Presentation
      import io, json, sys, zipfile
      p = Presentation(sys.argv[1])
      report = {"slides": len(p.slides._sldIdLst), "charts": [], "tables": 0}
      for s in p.slides:
          for sh in s.shapes:
              if sh.has_chart:
                  ch = sh.chart
                  plot = ch.plots[0]
                  report["charts"].append([
                      str(ch.chart_type).split()[0], len(list(plot.categories)),
                      [[se.name, len(list(se.values))] for se in plot.series], ch.has_legend,
                  ])
                  wb = zipfile.ZipFile(io.BytesIO(ch.part.chart_workbook.xlsx_part.blob))
                  assert wb.testzip() is None and "xl/worksheets/sheet1.xml" in wb.namelist()
              elif sh.has_table:
                  report["tables"] += 1
      print(json.dumps(report))
    PY
    output, status = Open3.capture2e("python3", "-I", "-c", "import pptx", { chdir: @dir })
    skip "python-pptx not available for verification (#{output.strip})" unless status.success?

    output, status = Open3.capture2e("python3", "-I", "-c", script, @path.to_s, { chdir: @dir })
    assert status.success?, "python-pptx failed to open the deck: #{output}"
    report = JSON.parse(output.lines.last)
    assert_equal FIXTURE_SLIDES.size, report["slides"]
    assert_equal CHART_SLIDES.values.sum, report["charts"].size
    # Chart type, category count, [series name, point count] and no legend — the
    # nil FY2021 margin still counts as a point (ptCount spans every category).
    assert_equal [
      ["LINE_MARKERS", 9, [["Mean tone", 9]], false],
      ["COLUMN_CLUSTERED", 6, [["Revenue (USDm)", 6]], false],
      ["LINE_MARKERS", 6, [["EBITDA margin", 6]], false],
      ["BAR_STACKED", 4, [["Base", 4], ["Range", 4]], false],
      ["COLUMN_CLUSTERED", 5, [["Unlevered FCF (USDm)", 5]], false]
    ], report["charts"]
    # KPI, themes, financials, comps x2, precedents, bridge + projections, sensitivity, buyers.
    assert_equal 10, report["tables"]
  end

  private

  def read_zip(path)
    read_zip_bytes(File.binread(path))
  end

  # rubyzip hands back binary strings; XML parts are UTF-8 (the declaration
  # says so), workbooks stay binary so they can be unzipped in turn.
  def read_zip_bytes(bytes)
    entries = {}
    Zip::File.open_buffer(bytes) do |zip|
      zip.each do |entry|
        content = entry.get_input_stream.read
        entries[entry.name] = entry.name.end_with?(".xlsx") ? content : content.force_encoding(Encoding::UTF_8)
      end
    end
    entries
  end

  # Strict parsing: a single stray character makes PowerPoint refuse the file,
  # so anything libxml2 would recover from must fail here instead.
  def parse_xml(bytes)
    Nokogiri::XML(bytes) { |config| config.strict.nonet }
  end

  def relationships(xml)
    parse_xml(xml).xpath("//*[local-name()='Relationship']").to_h do |node|
      [node["Id"], { type: node["Type"], target: node["Target"] }]
    end
  end

  # Every <a:t> on slide `number`, in document order; <a:br/> joins runs within a paragraph.
  def texts_of(number)
    doc = parse_xml(@entries["ppt/slides/slide#{number}.xml"])
    doc.xpath("//a:p", NS).filter_map do |para|
      runs = para.xpath("./a:r/a:t", NS).map(&:text)
      runs.join unless runs.empty?
    end
  end

  # Each table on slide `number` as rows of cell text.
  def tables_of(number) = tables_in(@entries["ppt/slides/slide#{number}.xml"])

  def tables_in(slide_xml)
    parse_xml(slide_xml).xpath("//a:tbl", NS).map do |table|
      table.xpath("./a:tr", NS).map do |row|
        row.xpath("./a:tc", NS).map { |cell| cell.xpath(".//a:t", NS).map(&:text).join }
      end
    end
  end

  # The XML of the index-th chart (0-based) referenced from slide `number`.
  def chart_xml_for(number, index)
    rels = relationships(@entries["ppt/slides/_rels/slide#{number}.xml.rels"])
    target = rels.values.select { |rel| rel[:type].end_with?("/chart") }[index][:target]
    @entries.fetch(target.sub("../", "ppt/"))
  end
end
