# frozen_string_literal: true

module Api
  # GET /api/transactions — precedent deals with multiple and premium
  # statistics (get_transactions in argos/api.py).
  class TransactionsController < BaseController
    def index
      render json: Valuation.precedent_transactions(sector: first(:sector).presence)
    end
  end
end
