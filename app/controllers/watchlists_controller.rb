# frozen_string_literal: true

# Create and delete watchlists from the monitor page (post_watchlist and
# delete_watchlist in argos/api.py).
class WatchlistsController < ApplicationController
  def create
    name = params[:name].to_s.strip
    return redirect_to(monitor_path, alert: "Watchlist name is required.", status: :see_other) if name.empty?

    # Creating a list that already exists reuses it, as the reference did.
    watchlist = Watchlist.find_or_create_by!(name: name)
    added = Array(params[:tickers]).filter_map do |ticker|
      company = Company.find_ticker(ticker)
      next unless company

      WatchlistItem.find_or_create_by!(watchlist_id: watchlist.id, company_id: company.id)
      company.ticker
    end
    notice = "Watchlist “#{watchlist.name}” ready"
    notice += " with #{added.join(', ')}" if added.any?
    redirect_to monitor_path, notice: "#{notice}.", status: :see_other
  end

  def destroy
    watchlist = Watchlist.find_by(id: params[:id])
    return redirect_to(monitor_path, alert: "Watchlist #{params[:id]} not found.", status: :see_other) unless watchlist

    # watchlist_items has no primary key, so its rows cannot be destroyed one
    # model at a time; delete them in SQL before the list itself.
    WatchlistItem.where(watchlist_id: watchlist.id).delete_all
    watchlist.destroy!
    redirect_to monitor_path, notice: "Deleted watchlist “#{watchlist.name}”.", status: :see_other
  end
end
