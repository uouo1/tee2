# frozen_string_literal: true

# Add a company to a watchlist, or remove one (post_watchlist_items and
# delete_watchlist_item in argos/api.py).
class WatchlistItemsController < ApplicationController
  before_action :load_watchlist

  def create
    tickers = Array(params[:tickers]).presence || [params[:ticker]].compact
    tickers = tickers.map { |t| t.to_s.strip.upcase }.reject(&:empty?)
    return redirect_to(monitor_path, alert: "Pick a company to add.", status: :see_other) if tickers.empty?

    companies = tickers.map { |ticker| [ticker, Company.find_ticker(ticker)] }
    # All or nothing: an unknown ticker rejects the request, as the reference's
    # 404 did, rather than adding the known ones silently.
    unknown = companies.select { |_, company| company.nil? }.map(&:first)
    return redirect_to(monitor_path, alert: "Unknown ticker: #{unknown.join(', ')}", status: :see_other) if unknown.any?

    companies.each do |_, company|
      WatchlistItem.find_or_create_by!(watchlist_id: @watchlist.id, company_id: company.id)
    end
    redirect_to monitor_path, notice: "Added #{tickers.join(', ')} to “#{@watchlist.name}”.", status: :see_other
  end

  def destroy
    ticker = params[:ticker].to_s.upcase
    company = Company.find_ticker(ticker)
    WatchlistItem.where(watchlist_id: @watchlist.id, company_id: company.id).delete_all if company
    redirect_to monitor_path, notice: "Removed #{ticker} from “#{@watchlist.name}”.", status: :see_other
  end

  private

  def load_watchlist
    @watchlist = Watchlist.find_by(id: params[:watchlist_id])
    redirect_to(monitor_path, alert: "Watchlist #{params[:watchlist_id]} not found.", status: :see_other) unless @watchlist
  end
end
