# frozen_string_literal: true

require "test_helper"

# Watchlist create/delete and item add/remove from the monitor page. Ports
# tests/test_api.py HandlerTests#test_watchlist_round_trip and
# #test_unknown_ticker_on_watchlist_is_rejected.
class WatchlistsControllerTest < ActionDispatch::IntegrationTest
  self.use_transactional_tests = false

  NAMES = ["Grid software", "L", "Duplicate"].freeze

  setup do
    Seed::Demo.seed! unless Document.exists?
    cleanup
  end

  teardown { cleanup }

  def cleanup
    Watchlist.where(name: NAMES).each do |list|
      WatchlistItem.where(watchlist_id: list.id).delete_all
      list.destroy
    end
  end

  def tickers_on(list)
    Company.where(id: WatchlistItem.where(watchlist_id: list.id).select(:company_id)).pluck(:ticker).sort
  end

  test "watchlist round trip" do
    post watchlists_path, params: { name: "Grid software", tickers: ["NVG"] }
    assert_redirected_to monitor_path
    list = Watchlist.find_by!(name: "Grid software")
    assert_equal ["NVG"], tickers_on(list)

    post watchlist_items_path(list), params: { tickers: ["HLDX"] }
    assert_redirected_to monitor_path
    assert_equal %w[HLDX NVG], tickers_on(list)

    follow_redirect!
    assert_select "#watchlist-#{list.id} tbody tr", 2

    delete watchlist_item_path(list, "HLDX")
    assert_redirected_to monitor_path
    assert_equal ["NVG"], tickers_on(list)

    delete watchlist_path(list)
    assert_redirected_to monitor_path
    assert_nil Watchlist.find_by(id: list.id)
    assert_equal 0, WatchlistItem.where(watchlist_id: list.id).count
  end

  test "a single ticker from the add form is accepted, lowercase included" do
    list = Watchlist.create!(name: "L")
    post watchlist_items_path(list), params: { ticker: "nvg" }
    assert_equal ["NVG"], tickers_on(list)
    # Adding it twice keeps one row.
    post watchlist_items_path(list), params: { ticker: "NVG" }
    assert_equal ["NVG"], tickers_on(list)
  end

  test "an unknown ticker on a watchlist is rejected" do
    list = Watchlist.create!(name: "L")
    post watchlist_items_path(list), params: { tickers: ["NOPE"] }
    assert_redirected_to monitor_path
    assert_equal "Unknown ticker: NOPE", flash[:alert]
    assert_empty tickers_on(list)
  end

  test "a watchlist needs a name, and an existing name is reused" do
    assert_no_difference -> { Watchlist.count } do
      post watchlists_path, params: { name: "   " }
    end
    assert_equal "Watchlist name is required.", flash[:alert]

    post watchlists_path, params: { name: "Duplicate" }
    assert_no_difference -> { Watchlist.count } do
      post watchlists_path, params: { name: "Duplicate" }
    end
  end

  test "an unknown watchlist redirects with a message" do
    post watchlist_items_path(10**7), params: { ticker: "NVG" }
    assert_redirected_to monitor_path
    assert_match(/not found/, flash[:alert])
    delete watchlist_path(10**7)
    assert_redirected_to monitor_path
    assert_match(/not found/, flash[:alert])
  end
end
