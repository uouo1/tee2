# frozen_string_literal: true

module Api
  # Watchlists (get_watchlists, post_watchlist, post_watchlist_items,
  # delete_watchlist_item and delete_watchlist in argos/api.py).
  class WatchlistsController < BaseController
    # Each member's tone and newest document. A company with no documents has
    # neither: null, not 0.
    MEMBERS_SQL = <<~SQL
      SELECT c.ticker, c.name, c.sector,
             (SELECT ROUND(AVG(d.sentiment), 3) FROM documents d WHERE d.company_id = c.id) AS sentiment,
             (SELECT MAX(d.published_at) FROM documents d WHERE d.company_id = c.id) AS latest
      FROM watchlist_items wi JOIN companies c ON c.id = wi.company_id
      WHERE wi.watchlist_id = ? ORDER BY c.ticker
    SQL

    def index
      lists = Watchlist.order(:name).map do |watchlist|
        watchlist.attributes.symbolize_keys.merge(companies: members(watchlist.id))
      end
      render json: { watchlists: lists }
    end

    # Creating a list that already exists reuses it; unknown tickers are
    # skipped here (adding to an existing list is where they are rejected).
    def create
      name = body_hash[:name].to_s.strip
      raise Error, "watchlist name is required" if name.empty?

      watchlist = Watchlist.find_or_create_by!(name: name)
      companies = Array(body_hash[:tickers]).filter_map { |ticker| Company.find_ticker(ticker.to_s.strip) }
      add(watchlist, companies)
      render json: { id: watchlist.id, name: watchlist.name }
    end

    # {"tickers": [...]} or {"ticker": "..."}. All or nothing: an unknown
    # ticker is a 404 and nothing is added (the reference added the tickers
    # before it in the list and then failed).
    def add_items
      watchlist = find_watchlist
      tickers = Array(body_hash[:tickers]).presence || [body_hash[:ticker]].compact
      tickers = tickers.map { |t| t.to_s.strip.upcase }.reject(&:empty?)
      raise Error, "ticker(s) required" if tickers.empty?

      companies = tickers.map do |ticker|
        Company.find_ticker(ticker) || raise(Error.new("unknown ticker: #{ticker}", 404))
      end
      add(watchlist, companies)
      render json: { watchlist_id: watchlist.id, added: tickers }
    end

    def remove_item
      watchlist_id = path_int
      ticker = path_param(:ticker).upcase
      company = Company.find_ticker(ticker)
      WatchlistItem.where(watchlist_id: watchlist_id, company_id: company.id).delete_all if company
      render json: { removed: ticker }
    end

    # Idempotent, as in the reference: deleting a missing list still reports it.
    # watchlist_items has no primary key, so its rows go in SQL first.
    def destroy
      watchlist_id = path_int
      Watchlist.transaction do
        WatchlistItem.where(watchlist_id: watchlist_id).delete_all
        Watchlist.where(id: watchlist_id).delete_all
      end
      render json: { deleted: watchlist_id }
    end

    private

    def find_watchlist
      id = path_int
      Watchlist.find_by(id: id) || raise(Error.new("watchlist #{id} not found", 404))
    end

    def members(watchlist_id)
      ActiveRecord::Base.connection.select_all(
        ActiveRecord::Base.sanitize_sql_array([MEMBERS_SQL, watchlist_id])
      ).to_a
    end

    # INSERT OR IGNORE: a ticker already on the list is not an error.
    def add(watchlist, companies)
      rows = companies.map(&:id).uniq.map { |id| { watchlist_id: watchlist.id, company_id: id } }
      WatchlistItem.insert_all(rows, unique_by: %i[watchlist_id company_id]) if rows.any?
    end
  end
end
