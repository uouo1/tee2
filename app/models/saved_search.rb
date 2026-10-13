# frozen_string_literal: true

class SavedSearch < ApplicationRecord
  validates :name, :query, presence: true

  def filters_hash
    JSON.parse(filters.presence || "{}", symbolize_names: true)
  rescue JSON::ParserError
    {}
  end
end
