# frozen_string_literal: true

require "test_helper"

# The pitch-book pages: create/show/preview/export/rebuild/destroy (the
# lifecycle of tests/test_api.py::test_pitchbook_lifecycle and the export
# HttpTests, through the HTML controllers), and every item-8 form: slide title
# edits that pin, move up/down, the comp-set chips, the assumptions form, and
# note-only evidence with its delete button.
class PitchbooksControllerTest < ActionDispatch::IntegrationTest
  self.use_transactional_tests = false

  setup do
    Seed::Demo.seed! unless Document.exists?
    @book = Pitchbooks.create!(title: "Project Pages", target_ticker: "NVG", client_name: "Board")
    @created = [@book]
    @exports = []
  end

  teardown do
    Pitchbook.where(id: @created.map(&:id)).or(Pitchbook.where("title LIKE 'Project Web%'")).each { |book| Pitchbooks.delete!(book) }
    Dir.glob(Rails.root.join("tmp/exports", "Project-Pages-#{@book.id}.*")).each { |f| File.delete(f) }
  end

  test "index shows the new-deck form and the deck list" do
    get pitchbooks_path
    assert_response :success
    assert_select "form#book-form select[name='pitchbook[target_ticker]']"
    assert_select "form#book-form input[name='pitchbook[title]']"
    assert_select "form#book-form input[name='pitchbook[client_name]']"
    assert_select "form#book-form input[name='pitchbook[banker]']"
    assert_select "#book-comps input[type=checkbox][name='pitchbook[comp_tickers][]']", minimum: 5
    assert_select "a.book-item[href='#{pitchbook_path(@book)}']", text: /Project Pages/
  end

  test "suggest comparables re-renders with the target's suggestions ticked" do
    get pitchbooks_path, params: { pitchbook: { target_ticker: "PYLN" } }
    assert_response :success
    assert_select "select[name='pitchbook[target_ticker]'] option[selected][value=PYLN]"
    assert_select "#book-comps input[value=PYLN]", count: 0
    Pitchbooks.suggest_comps("PYLN").each do |ticker|
      assert_select "#book-comps input[value=#{ticker}][checked]"
    end
  end

  test "create generates a deck and redirects to it" do
    assert_difference -> { Pitchbook.count }, 1 do
      post pitchbooks_path, params: { pitchbook: { target_ticker: "nvg", title: "Project Web Create", banker: "Argos",
                                                   comp_tickers: ["", "TWSW", "MFCL"] } }
    end
    book = Pitchbook.order(:id).last
    @created << book
    assert_redirected_to pitchbook_path(book)
    assert_equal 303, response.status
    assert_equal %w[MFCL TWSW], book.comp_tickers
    assert_equal 14, book.slides.count
    follow_redirect!
    assert_response :success
    assert_select "h1", "Project Web Create"
  end

  test "create without a target or with an unknown one re-renders the form" do
    assert_no_difference -> { Pitchbook.count } do
      post pitchbooks_path, params: { pitchbook: { title: "Project Web Missing" } }
    end
    assert_response :unprocessable_content
    assert_select "[role=alert]", /Choose a target/
    post pitchbooks_path, params: { pitchbook: { target_ticker: "NOPE", title: "Project Web Nope" } }
    assert_response :unprocessable_content
    assert_select "[role=alert]", /unknown target ticker: NOPE/
  end

  test "show carries the toolbar, the forms, the stamp and the preview" do
    get pitchbook_path(@book)
    assert_response :success
    %w[html pdf pptx].each { |fmt| assert_select "a[href='#{export_pitchbook_path(@book, format: fmt)}']", text: "Export #{fmt.upcase}" }
    assert_select "form[action='#{rebuild_pitchbook_path(@book)}']"
    assert_select "form[action='#{pitchbook_path(@book)}'] input[name=_method][value=delete]"
    assert_select "details#assumptions form[action='#{assumptions_pitchbook_path(@book)}'] input[name='assumptions[wacc]']"
    assert_select "details#comps form[action='#{comps_pitchbook_path(@book)}'] input[name='tickers[]'][checked]", count: @book.comp_tickers.size
    assert_select "details#slide-editor form[action='#{slide_path(@book.slides.first)}'] input[name='slide[title]']"
    assert_select "details#slide-editor form[action='#{reorder_pitchbook_path(@book)}'] input[name=direction][value=down]"
    assert_select "details#evidence form[action='#{pitchbook_evidences_path(@book)}'] textarea[name='evidence[quote]']"
    assert_select "p.stamp", /code (\h+|unknown)/
    assert_select ".deck-preview section.slide", 14
    assert_select ".stale-warning", count: 0
  end

  test "show warns when documents are newer than the deck" do
    ActiveRecord::Base.transaction do
      Document.order(:id).first.update_columns(created_at: 1.hour.from_now)
      get pitchbook_path(@book)
      assert_select ".stale-warning", /added to the corpus after these slides were built/
      raise ActiveRecord::Rollback
    end
  end

  test "preview returns the deck markup without the layout" do
    get preview_pitchbook_path(@book)
    assert_response :success
    assert_equal 14, response.body.scan('<section class="slide').size
    assert_not_includes response.body, "<html"
  end

  test "export sends an attachment for every format" do
    get export_pitchbook_path(@book, format: "html")
    assert_response :success
    assert_includes response.headers["Content-Disposition"], "attachment;"
    assert_includes response.body[0, 200].downcase, "<!doctype html>"
    get export_pitchbook_path(@book), params: { format: "pdf" }
    assert_response :success
    assert response.body.start_with?("%PDF")
    get export_pitchbook_path(@book, format: "pptx")
    assert_response :success
    assert response.body.start_with?("PK")
    assert(Dir.glob(Rails.root.join("tmp/exports", "Project-Pages-#{@book.id}.*")).size >= 3)
    assert_empty Dir.glob(Rails.root.join("data/exports", "Project-Pages-#{@book.id}.*"))
  end

  test "export metadata without download and unknown formats" do
    get export_pitchbook_path(@book, format: "html"), params: { download: "0" }
    payload = JSON.parse(response.body)
    assert_equal "html", payload["format"]
    assert_operator payload["bytes"], :>, 0
    assert payload["path"].start_with?(Rails.root.join("tmp/exports").to_s)
    get export_pitchbook_path(@book), params: { format: "xlsx" }
    assert_redirected_to pitchbook_path(@book)
    assert_match(/unavailable: xlsx/, flash[:alert])
  end

  test "rebuild regenerates unpinned slides" do
    process = @book.slides.find { |s| s.kind == "process" }
    process.update_columns(title: "Stale")
    post rebuild_pitchbook_path(@book)
    assert_redirected_to pitchbook_path(@book)
    assert_equal "Process considerations and next steps", @book.slides.reload.find { |s| s.kind == "process" }.title
  end

  test "destroy removes the deck" do
    book = Pitchbooks.create!(title: "Project Web Delete", target_ticker: "PYLN")
    @created << book
    delete pitchbook_path(book)
    assert_redirected_to pitchbooks_path
    assert_equal 303, response.status
    assert_not Pitchbook.exists?(book.id)
    get pitchbook_path(book)
    assert_response :not_found
  end

  test "editing a slide title pins it and unpin hands it back" do
    slide = @book.slides.find { |s| s.kind == "executive_summary" }
    patch slide_path(slide), params: { slide: { title: "Our view", subtitle: "Board discussion" } }
    assert_redirected_to pitchbook_path(@book, anchor: "edit-slide-#{slide.id}")
    slide.reload
    assert_equal "Our view", slide.title
    assert_equal "Board discussion", slide.subtitle
    assert slide.is_pinned
    post rebuild_pitchbook_path(@book)
    assert_equal "Our view", @book.slides.reload.find { |s| s.kind == "executive_summary" }.title

    patch slide_path(slide), params: { slide: { pin: "0" } }
    assert_not slide.reload.is_pinned
    assert_equal "Our view", slide.title
    post rebuild_pitchbook_path(@book)
    assert_equal "Executive summary", @book.slides.reload.find { |s| s.kind == "executive_summary" }.title

    patch slide_path(10**7), params: { slide: { title: "x" } }
    assert_response :not_found
  end

  test "move a slide up and down" do
    ids = @book.slides.map(&:id)
    post reorder_pitchbook_path(@book), params: { slide_id: ids[4], direction: "up" }
    assert_redirected_to pitchbook_path(@book, anchor: "edit-slide-#{ids[4]}")
    assert_equal ids[4], @book.slides.reload[3].id
    post reorder_pitchbook_path(@book), params: { slide_id: ids[4], direction: "down" }
    assert_equal ids, @book.slides.reload.map(&:id)
    post reorder_pitchbook_path(@book), params: { slide_ids: ids.reverse }
    assert_equal ids.reverse, @book.slides.reload.map(&:id)
    post reorder_pitchbook_path(@book)
    assert_match(/Nothing to reorder/, flash[:alert])
  end

  test "the comp chips change the comp set" do
    post comps_pitchbook_path(@book), params: { tickers: ["", "TWSW", "MFCL"] }
    assert_redirected_to pitchbook_path(@book)
    assert_equal %w[MFCL TWSW], @book.comp_tickers
    rows = @book.slides.reload.find { |s| s.kind == "trading_comps" }.payload_hash[:rows]
    assert_equal %w[MFCL TWSW].to_set, rows.map { |r| r[:ticker] }.to_set
  end

  test "the assumptions form applies overrides and rejects bad ones" do
    post assumptions_pitchbook_path(@book), params: { assumptions: { wacc: "0.12", years: "", bogus: "1" } }
    assert_redirected_to pitchbook_path(@book)
    assert_in_delta 0.12, @book.reload.assumptions_hash[:wacc]
    assert_in_delta 0.12, @book.slides.find { |s| s.kind == "dcf" }.payload_hash[:assumptions][:wacc]
    post assumptions_pitchbook_path(@book), params: { assumptions: { terminal_growth: "0.5" } }
    assert_match(/Assumptions not applied/, flash[:alert])
    assert_nil @book.reload.assumptions_hash[:terminal_growth]
    get pitchbook_path(@book)
    assert_select "input[name='assumptions[wacc]'][value='0.12']"
  end

  test "note-only evidence is added and removed" do
    slide = @book.slides.find { |s| s.kind == "process" }
    post pitchbook_evidences_path(@book), params: { evidence: { quote: "Check the <b>churn</b> definition.", note: "Diligence", slide_id: slide.id } }
    assert_redirected_to pitchbook_path(@book, anchor: "evidence")
    evidence = Evidence.where(pitchbook_id: @book.id).last
    assert_equal "Check the <b>churn</b> definition.", evidence.quote
    assert_nil evidence.document_id
    assert_equal slide.id, evidence.slide_id
    items = @book.slides.reload.find { |s| s.kind == "evidence_appendix" }.payload_hash[:items]
    assert_equal 1, items.size

    get pitchbook_path(@book)
    assert_includes response.body, "Check the &lt;b&gt;churn&lt;/b&gt; definition."
    assert_select "form[action='#{evidence_path(evidence)}'] input[name=_method][value=delete]"

    delete evidence_path(evidence)
    assert_redirected_to pitchbook_path(@book, anchor: "evidence")
    assert_not Evidence.exists?(evidence.id)
    assert_equal [], @book.slides.reload.find { |s| s.kind == "evidence_appendix" }.payload_hash[:items]

    post pitchbook_evidences_path(@book), params: { evidence: { quote: "  " } }
    assert_match(/Evidence requires a quote/, flash[:alert])
  end

  test "evidence pinned from a research passage keeps its chunk and document" do
    chunk = Chunk.where("length(text) > 120").order(:id).first
    post pitchbook_evidences_path(@book), params: { evidence: { quote: "", chunk_id: chunk.id } },
                                          headers: { "HTTP_REFERER" => "http://www.example.com/research?q=margin" }
    assert_redirected_to "http://www.example.com/research?q=margin"
    evidence = Evidence.where(pitchbook_id: @book.id).last
    assert_equal chunk.id, evidence.chunk_id
    assert_equal chunk.document_id, evidence.document_id
    assert_equal chunk.text.strip[0, 2000], evidence.quote
  end
end
