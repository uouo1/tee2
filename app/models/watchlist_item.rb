# frozen_string_literal: true

class WatchlistItem < ApplicationRecord
  belongs_to :watchlist
  belongs_to :company
end
