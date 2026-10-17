# frozen_string_literal: true

require "test_helper"

# The research page: GET form, facet links, summary, results, reader, pin.
# Ports the search half of tests/test_api.py (repeated doc_type filters,
# limit) to the server-rendered page, plus what the page itself adds.
class ResearchControllerTest < ActionDispatch::IntegrationTest
  self.use_transactional_tests = false

  setup do
    Seed::Demo.seed! unless Document.exists?
    @created_books = []
  end

  teardown { Pitchbook.where(id: @created_books).destroy_all }

  test "opening the page browses newest first" do
    get research_path
    assert_response :success
    assert_select "form#search-form[method=get][action=?]", "/research"
    assert_select "input#q[name=q]"
    newest = Document.newest_first.first
    assert_select "#results article.result", ResearchController::PAGE_SIZE
    assert_select "#results article.result:first-child .title", text: newest.title
    assert_select "#results-meta", /#{Document.count} documents/
    assert_select "nav.tabs a.tab[aria-current=page]", text: "Research"
  end

  test "a query highlights matches, summarises with citations and offers pinning" do
    get research_path(q: "margin")
    assert_response :success
    result = Search.search("margin", {}, limit: ResearchController::PAGE_SIZE)
    assert_select "#results article.result", result[:results].size
    assert_select "#results .snippet mark"
    assert_select "#results-meta", /#{result[:total_documents]} documents? · .* ms/
    if result.dig(:summary, :bullets).present?
      assert_select ".summary-card li", result[:summary][:bullets].size
      assert_select ".summary-card li a.cite"
    end
    first = result[:results].first
    assert_select "button[data-action='pin-dialog#open'][data-pin-dialog-document-id-param=?][data-pin-dialog-chunk-id-param=?]",
                  first[:document_id].to_s, first[:chunk_id].to_s
    # The pin quote is plain text: no markup and no ellipsis at either end.
    quote = css_select("#results article.result:first-child button[data-action='pin-dialog#open']").first["data-pin-dialog-quote-param"]
    refute_includes quote, "<mark>"
    refute quote.start_with?("…")
  end

  test "repeated doc_type filters restrict the results" do
    get research_path(q: "revenue", doc_type: %w[filing transcript])
    assert_response :success
    # The document-type pill is the first pill after the ticker in each card.
    types = css_select("#results article.result .meta").map { |meta| meta.css("span.pill:not(.ticker)").first.text }
    refute_empty types
    assert_empty types - %w[filing transcript]
    # The selected facets are pressed and their links remove them again.
    assert_select "#facets a.facet-item[aria-pressed=true]", minimum: 1
  end

  test "facet links toggle doc_type, ticker and sentiment parameters" do
    get research_path(q: "margin")
    ticker_link = css_select("#facets a.facet-item").find { |a| a["href"].include?("ticker") }
    assert ticker_link, "a company facet link"
    href = ticker_link["href"]
    assert_match(/ticker%5B%5D=|ticker\[\]=/, href)
    get href
    assert_response :success
    selected = css_select("#facets a.facet-item[aria-pressed=true]")
    refute_empty selected
    # Following the pressed link again removes the filter.
    get selected.first["href"]
    assert_response :success
    assert_select "#facets a.facet-item[aria-pressed=true]", 0

    get research_path(q: "margin", sentiment: "positive")
    assert_response :success
    assert_select "input[type=hidden][name=sentiment][value=positive]"
    pressed = css_select("#facets a.facet-item[aria-pressed=true]").map { |a| a.css("span").first.text }
    assert_includes pressed, "positive"
  end

  test "the year facet adds and removes a date: filter" do
    get research_path(q: "margin")
    year_link = css_select("#facets a.facet-item").find { |a| a["href"].include?("date%3A") }
    assert year_link, "a year facet link"
    year = year_link.css("span").first.text
    assert_includes CGI.unescape(year_link["href"]), "q=margin date:#{year}"
    get year_link["href"]
    assert_response :success
    css_select("#results article.result .meta span:not(.pill)").each do |node|
      next unless node.text.match?(/\A\d{4}-\d{2}-\d{2}\z/)

      assert node.text.start_with?(year), "#{node.text} is in #{year}"
    end
  end

  test "example chips use the first company ticker" do
    get research_path
    ticker = Company.order(:ticker).first.ticker
    assert_select "#examples a.chip", 6
    assert_select "#examples a.chip", text: "ticker:#{ticker} cash flow"
  end

  test "expand checkbox is on by default and off when unticked" do
    get research_path(q: "guidance")
    assert_select "input#expand[checked]"
    get research_path(q: "guidance", expand: "0")
    assert_select "input#expand[checked]", 0
    assert_select "#results-meta", text: /matched on/, count: 0
  end

  test "pagination covers results beyond the first page" do
    total = Document.count
    skip "corpus smaller than one page" if total <= ResearchController::PAGE_SIZE

    get research_path
    assert_select "nav.pager a", text: "Next →"
    get research_path(offset: ResearchController::PAGE_SIZE)
    assert_response :success
    assert_select "nav.pager a", text: "← Previous"
  end

  test "the reader opens a document beside the results" do
    document = Document.joins(:kpis).first || Document.first
    get research_path(q: "margin", document: document.id)
    assert_response :success
    assert_select "#reader h2", text: document.title
    assert_select "#reader .passage", document.chunks.count
    assert_select "#reader .passage button[data-action='pin-dialog#open']", document.chunks.count
    assert_select "#reader h2", text: "Extracted metrics" if document.kpis.any?
    assert_select "#reader a[href=?]", "/documents/#{document.id}"
  end

  test "an unknown document in the reader says so" do
    get research_path(document: 10**7)
    assert_response :success
    assert_select "#reader .empty", /not found/
  end

  test "the pin dialog lists pitch books and posts to their evidences route" do
    company = Company.order(:ticker).first
    book = Pitchbook.create!(title: "Project Pin", target_company: company)
    @created_books << book.id
    get research_path(q: "margin")
    assert_select "[data-controller=pin-dialog] dialog#pin-dialog"
    assert_select "dialog#pin-dialog option[value=?][data-url=?]", book.id.to_s, "/pitchbooks/#{book.id}/evidences",
                  text: "Project Pin (#{company.ticker})"
    assert_select "dialog#pin-dialog form[method=post]"
    %w[quote document_id chunk_id note].each { |field| assert_select "dialog#pin-dialog [name=?]", "evidence[#{field}]" }
  end

  test "the pin dialog's fields are what the evidences route accepts" do
    company = Company.order(:ticker).first
    book = Pitchbook.create!(title: "Project Pin", target_company: company)
    @created_books << book.id
    chunk = Chunk.joins(:document).where(documents: { company_id: company.id }).first || Chunk.first
    get research_path(q: "margin", document: chunk.document_id)
    form = css_select("dialog#pin-dialog form").first
    names = form.css("[name^=evidence]").map { |node| node["name"] }
    params = names.to_h { |name| [name, ""] }
    params["evidence[quote]"] = chunk.text
    params["evidence[document_id]"] = chunk.document_id.to_s
    params["evidence[chunk_id]"] = chunk.id.to_s
    params["evidence[note]"] = "Why this matters"
    action = css_select("dialog#pin-dialog option[value='#{book.id}']").first["data-url"]

    assert_difference -> { Evidence.where(pitchbook_id: book.id).count }, 1 do
      post action, params: params, headers: { "HTTP_REFERER" => research_url(q: "margin", document: chunk.document_id) }
    end
    evidence = Evidence.where(pitchbook_id: book.id).last
    assert_equal [chunk.id, chunk.document_id, "Why this matters"], [evidence.chunk_id, evidence.document_id, evidence.note]
    assert_redirected_to research_url(q: "margin", document: chunk.document_id)
  end

  test "save this search carries the query and filters" do
    get research_path(q: "pricing", doc_type: ["transcript"])
    assert_select "form[action='/saved_searches'] input[name=query][value=pricing]"
    assert_select "form[action='/saved_searches'] input[name='doc_type[]'][value=transcript]"
  end
end
