# frozen_string_literal: true

class Watchlist < ApplicationRecord
  has_many :watchlist_items, dependent: :destroy
  has_many :companies, through: :watchlist_items
  validates :name, presence: true, uniqueness: true
end
