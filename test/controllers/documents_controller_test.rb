# frozen_string_literal: true

require "test_helper"

# documents#show: the reader on a page of its own. Ports
# tests/test_api.py HandlerTests#test_document_not_found_raises_api_error.
class DocumentsControllerTest < ActionDispatch::IntegrationTest
  self.use_transactional_tests = false

  setup { Seed::Demo.seed! unless Document.exists? }

  test "a document page shows metadata, passages, metrics and similar documents" do
    document = Document.joins(:kpis).first || Document.first
    get document_path(document)
    assert_response :success
    assert_select "title", /#{Regexp.escape(document.title)}/
    assert_select ".reader h2", text: document.title
    assert_select ".passage", document.chunks.count
    document.chunks.each { |chunk| assert_select "#passage-#{chunk.id}" }
    assert_select ".reader h2", text: "Extracted metrics" if document.kpis.any?
    similar = Search.similar_documents(document.id)
    assert_select ".reader h2", text: "Similar documents" if similar.any?
    similar.each { |row| assert_select "a.company-item[href=?]", "/documents/#{row[:document_id]}" }
    assert_select "[data-controller=pin-dialog] dialog#pin-dialog"
    assert_select "nav.tabs a.tab[aria-current=page]", text: "Research"
  end

  test "a company document links to its company" do
    document = Document.where.not(company_id: nil).first
    get document_path(document)
    assert_select "a[href=?]", "/companies/#{document.company.ticker}"
  end

  test "an unknown document is a 404 page" do
    get document_path(10**7)
    assert_response :not_found
    assert_select "h1", /not found/
  end
end
