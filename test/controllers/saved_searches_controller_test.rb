# frozen_string_literal: true

require "test_helper"

# Saving a research query for the monitor. Ports tests/test_api.py
# HandlerTests#test_saved_search_requires_a_query and the save half of
# #test_saved_search_alerts_report_new_documents.
class SavedSearchesControllerTest < ActionDispatch::IntegrationTest
  self.use_transactional_tests = false

  setup do
    Seed::Demo.seed! unless Document.exists?
    SavedSearch.delete_all
  end

  teardown { SavedSearch.delete_all }

  test "a saved search requires a query" do
    assert_no_difference -> { SavedSearch.count } do
      post saved_searches_path, params: { name: "x", query: "  " }
    end
    assert_equal "Type a query first.", flash[:alert]
    assert_redirected_to research_path
  end

  test "saving keeps the query and filters and starts at the newest document" do
    post saved_searches_path, params: { query: "pricing pressure", name: "", doc_type: ["transcript"],
                                        sentiment: "negative", expand: "0" }
    saved = SavedSearch.last
    assert_equal "pricing pressure", saved.name
    assert_equal "pricing pressure", saved.query
    assert_equal({ doc_type: ["transcript"], sentiment: "negative" }, saved.filters_hash)
    assert_equal Document.maximum(:id), saved.last_seen_document_id
    assert_redirected_to research_path(doc_type: ["transcript"], sentiment: "negative", q: "pricing pressure", expand: "0")
    assert_equal "Saved. New matches will appear under Monitor.", flash[:notice]

    # Nothing is new yet, so no alert.
    assert_equal 0, Analytics.check_alerts.first[:new_documents]
  end

  test "a long query is truncated for the name" do
    query = "pricing " * 20
    post saved_searches_path, params: { query: query }
    assert_equal query.strip[0, 60], SavedSearch.last.name
  end

  test "an alert counts new documents and stops once marked seen" do
    post saved_searches_path, params: { query: "pricing pressure", name: "Pricing" }
    saved = SavedSearch.last
    saved.update_column(:last_seen_document_id, 0)
    assert Analytics.check_alerts.first[:new_documents].positive?
    Analytics.check_alerts(mark_seen: true)
    assert_equal 0, Analytics.check_alerts.first[:new_documents]
  end

  test "remove deletes the saved search" do
    saved = SavedSearch.create!(name: "x", query: "margin", last_seen_document_id: 0)
    delete saved_search_path(saved)
    assert_redirected_to monitor_path
    assert_nil SavedSearch.find_by(id: saved.id)
  end
end
