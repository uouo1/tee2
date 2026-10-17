# frozen_string_literal: true

# Alerts, saved searches and watchlists.
#
# Port of loadMonitor() in argos/static/app.js. Alerts are computed on every
# visit from Analytics.check_alerts without marking anything seen, exactly as
# the reference page did (GET must not move the watermark).
class MonitorController < ApplicationController
  helper DashboardController::Formatting

  def index
    @alerts = Analytics.check_alerts(mark_seen: false)
    @live_alerts = @alerts.select { |alert| alert[:new_documents].to_i.positive? }
    @saved_searches = SavedSearch.order(id: :desc).to_a
    @watchlists = Watchlist.order(:name).to_a
    @watchlist_companies = @watchlists.to_h { |list| [list.id, watchlist_companies(list.id)] }
    @companies = Company.order(:ticker).pluck(:ticker, :name)
  end

  private

  # The reference's get_watchlists row: tone and newest document per name.
  def watchlist_companies(watchlist_id)
    sql = ActiveRecord::Base.sanitize_sql_array([<<~SQL, watchlist_id])
      SELECT c.ticker, c.name, c.sector,
             (SELECT ROUND(AVG(d.sentiment), 3) FROM documents d WHERE d.company_id = c.id) AS sentiment,
             (SELECT MAX(d.published_at) FROM documents d WHERE d.company_id = c.id) AS latest
      FROM watchlist_items wi JOIN companies c ON c.id = wi.company_id
      WHERE wi.watchlist_id = ? ORDER BY c.ticker
    SQL
    ActiveRecord::Base.connection.select_all(sql).to_a.map(&:symbolize_keys)
  end
end
