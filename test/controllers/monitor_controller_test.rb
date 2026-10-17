# frozen_string_literal: true

require "test_helper"

# The monitor page: alerts from saved searches, the saved searches, and
# watchlists. Ports tests/test_api.py
# HandlerTests#test_saved_search_alerts_report_new_documents to the page.
class MonitorControllerTest < ActionDispatch::IntegrationTest
  self.use_transactional_tests = false

  setup do
    Seed::Demo.seed! unless Document.exists?
    SavedSearch.delete_all
    Watchlist.where(name: "Monitor test list").each do |list|
      WatchlistItem.where(watchlist_id: list.id).delete_all
      list.destroy
    end
  end

  teardown do
    SavedSearch.delete_all
    Watchlist.where(name: "Monitor test list").each do |list|
      WatchlistItem.where(watchlist_id: list.id).delete_all
      list.destroy
    end
  end

  test "empty states" do
    get monitor_path
    assert_response :success
    assert_select "#alerts .empty", /Save a search from the Research tab/
    assert_select "#saved-searches .empty", "Nothing saved yet."
    assert_select "nav.tabs a.tab[aria-current=page]", text: "Monitor"
  end

  test "a saved search with an old watermark alerts with the true document count" do
    saved = SavedSearch.create!(name: "Pricing", query: "pricing pressure", last_seen_document_id: 0)
    expected = Search.search("pricing pressure", { min_document_id: 0 }, limit: 10, summarize: false)[:total_documents]
    assert expected.positive?

    get monitor_path
    assert_response :success
    assert_select "#alerts h3", text: "Pricing — #{expected} new"
    assert_select "#alerts article.result", [expected, 4].min
    assert_select "#saved-searches a.company-item[href=?]", "/research?q=pricing+pressure"
    assert_select "#saved-searches form[action=?] input[name=_method][value=delete]", "/saved_searches/#{saved.id}"
    # Viewing the page does not mark anything seen.
    assert_equal 0, saved.reload.last_seen_document_id
  end

  test "an up-to-date saved search raises no alert" do
    SavedSearch.create!(name: "Pricing", query: "pricing pressure", last_seen_document_id: Document.maximum(:id))
    get monitor_path
    assert_select "#alerts .empty", "No new documents match your saved searches."
  end

  test "saved filters are kept on the research link" do
    SavedSearch.create!(name: "Calls", query: "margin", filters: JSON.generate(doc_type: ["transcript"]),
                        last_seen_document_id: 0)
    get monitor_path
    assert_select "#saved-searches a.company-item[href=?]", "/research?doc_type%5B%5D=transcript&q=margin"
  end

  test "watchlists show their companies with tone, latest document and add/remove controls" do
    list = Watchlist.create!(name: "Monitor test list")
    company = Company.find_ticker("NVG")
    WatchlistItem.create!(watchlist_id: list.id, company_id: company.id)
    get monitor_path
    assert_select "#watchlist-#{list.id} strong", "Monitor test list"
    assert_select "#watchlist-#{list.id} tbody tr", 1
    assert_select "#watchlist-#{list.id} a[href=?]", "/companies/NVG"
    latest = Document.where(company_id: company.id).maximum(:published_at).to_s
    assert_select "#watchlist-#{list.id} td", text: latest
    assert_select "#watchlist-#{list.id} form[action=?]", "/watchlists/#{list.id}/items/NVG"
    assert_select "#watchlist-#{list.id} form[action=?] select[name=ticker]", "/watchlists/#{list.id}/items"
    # A company already on the list is not offered again.
    assert_select "#watchlist-#{list.id} select[name=ticker] option[value=NVG]", 0
    assert_select "form#watchlist-form[action=?] input[name=name]", "/watchlists"
  end
end
