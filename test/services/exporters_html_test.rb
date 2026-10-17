# frozen_string_literal: true

require "test_helper"
require "tmpdir"

# Port of tests/test_api.py::ExportTests for the HTML deck (and the dispatch in
# Exporters.export for every format), plus the port's additions: the export
# directory under tmp/ in tests (RAILS_PORT.md item 10), escaping of every
# untrusted field, the fallback for unknown kinds, and payloads with nils.
class ExportersHtmlTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  Deck = Struct.new(:title, :slides, keyword_init: true)
  SlideFixture = Struct.new(:kind, :title, :subtitle, :payload_hash, keyword_init: true)

  setup do
    Seed::Demo.seed! unless Document.exists?
    @book = Pitchbooks.create!(title: "Project Export", target_ticker: "NVG", client_name: "Board")
    Pitchbooks.add_evidence!(@book, quote: "Churn ticked up to 5.2%.", document_id: Document.order(:id).first.id)
    @book.reload
  end

  teardown do
    Pitchbooks.delete!(@book) if @book && Pitchbook.exists?(@book.id)
  end

  test "html deck is self-contained" do
    markup = Exporters::Html.render(@book)
    assert_includes markup.downcase, "<!doctype html>"
    assert_equal @book.slides.size, markup.scan('<section class="slide').size
    assert_not_includes markup.gsub("http://www.w3.org", ""), "http://" # no external assets
    assert_not_includes markup, "https://"
    assert_no_match(/<link|<script/i, markup)
    assert_includes markup, "prefers-color-scheme: dark"
    assert_includes markup, ':root[data-theme="dark"]'
    assert_includes markup, "--series-1: #2a78d6;"
    assert_includes markup, "--series-1: #3987e5;"
    assert_includes markup, ".heat-ref"
    assert_includes markup, "<title>Project Export</title>"
  end

  test "deck body matches slide count" do
    body = Exporters::Html.render_body(@book)
    assert_equal @book.slides.size, body.scan('<section class="slide').size
    assert_not_includes body.downcase, "<!doctype"
    assert_includes body, "<svg"
    assert_includes body, "Churn ticked up to 5.2%."
  end

  test "html escapes untrusted text" do
    deck = Deck.new(title: "<b>t</b>", slides: [
      SlideFixture.new(kind: "process", title: "<script>alert(1)</script>", subtitle: "<i>sub</i>",
                       payload_hash: { bullets: ["<img src=x onerror=alert(1)>"] }),
      SlideFixture.new(kind: "cover", title: "Cover", subtitle: nil,
                       payload_hash: { client_name: "<script>c</script>", target: "<b>T</b>", stamp: { code_version: "<x>" } }),
      SlideFixture.new(kind: "evidence_appendix", title: "Appendix", subtitle: nil,
                       payload_hash: { items: [{ quote: "<img src=y>", note: "<u>n</u>", title: "<em>doc</em>", document_id: 1 }] }),
      SlideFixture.new(kind: "trading_comps", title: "Comps", subtitle: nil,
                       payload_hash: { target: { ticker: "<T>", name: "<script>n</script>", is_target: true, ev_ebitda: 10.0 },
                                       rows: [], stats: {}, footnote: "<b>f</b>" })
    ])
    markup = Exporters::Html.render_body(deck)
    assert_not_includes markup, "<script>"
    assert_not_includes markup, "<img src=x"
    assert_not_includes markup, "<img src=y"
    assert_not_includes markup, "<i>sub</i>"
    assert_not_includes markup, "<u>n</u>"
    assert_not_includes markup, "<b>f</b>"
    assert_includes markup, "&lt;script&gt;alert(1)&lt;/script&gt;"
    assert_includes markup, "&lt;img src=x onerror=alert(1)&gt;"
    full = Exporters::Html.render(deck)
    assert_includes full, "<title>&lt;b&gt;t&lt;/b&gt;</title>"
  end

  test "unknown kinds and empty payloads render without raising" do
    kinds = Pitchbooks::SLIDE_ORDER.map(&:first) + ["mystery"]
    deck = Deck.new(title: "Empty", slides: kinds.map { |kind| SlideFixture.new(kind: kind, title: kind, subtitle: nil, payload_hash: {}) })
    body = Exporters::Html.render_body(deck)
    assert_equal kinds.size, body.scan('<section class="slide').size
    fallback = Deck.new(title: "F", slides: [SlideFixture.new(kind: "mystery", title: "M", subtitle: nil, payload_hash: { bullets: ["one", { text: "two" }] })])
    assert_includes Exporters::Html.render_body(fallback), "<li>two"
  end

  test "dcf slide has D&A, nwc change and a terminal row" do
    body = Exporters::Html.render_body(@book)
    dcf = body[/<section class="slide" data-kind="dcf".*?<\/section>/m]
    assert dcf
    assert_includes dcf, "D&amp;A"
    assert_includes dcf, "ΔNWC"
    assert_includes dcf, 'data-row="terminal"'
    assert_includes dcf, "WACC build"
  end

  test "the cover shows the stamp" do
    body = Exporters::Html.render_body(@book)
    cover = body[/<section class="slide cover".*?<\/section>/m]
    assert_match(/Data as of \d{4}-\d\d-\d\d · prices as of \d{4}-\d\d-\d\d · built \d{4}-\d\d-\d\d · code (\h+|unknown)/, cover)
  end

  test "every available format writes a file" do
    formats = Exporters.available_formats
    assert_equal({ html: true, pptx: true, pdf: true }, formats)
    Dir.mktmpdir do |tmp|
      formats.each do |fmt, supported|
        next unless supported

        path = Exporters.export(@book, fmt, File.join(tmp, "deck.#{fmt}"))
        assert path.exist?, fmt
        assert_operator path.size, :>, 1000, fmt
      end
    end
  end

  test "unsupported format raises" do
    Dir.mktmpdir do |tmp|
      assert_raises(ArgumentError) { Exporters.export(@book, "xlsx", File.join(tmp, "deck.xlsx")) }
    end
  end

  test "exports default under tmp in tests and honour ARGOS_EXPORT_DIR" do
    assert_equal Rails.root.join("tmp/exports"), Exporters.export_dir
    path = Exporters.export(@book, "html")
    assert_equal Rails.root.join("tmp/exports", "Project-Export-#{@book.id}.html"), path
    assert path.exist?
    path.delete
    Dir.mktmpdir do |tmp|
      previous = ENV["ARGOS_EXPORT_DIR"]
      ENV["ARGOS_EXPORT_DIR"] = tmp
      begin
        assert_equal Pathname(tmp), Exporters.export_dir
        assert Exporters.export(@book, :html).to_s.start_with?(tmp)
      ensure
        ENV["ARGOS_EXPORT_DIR"] = previous
      end
    end
    assert_equal "pitchbook.pdf", Exporters.filename_for(Deck.new(title: "///", slides: []), "pdf")
  end
end
