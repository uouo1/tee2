# frozen_string_literal: true

module Api
  # GET /api/search — get_search in argos/api.py.
  class SearchController < BaseController
    # Filters that may repeat (?doc_type=filing&doc_type=transcript).
    MULTI_FILTERS = %w[doc_type ticker].freeze
    SINGLE_FILTERS = %w[company sector source author sentiment date_from date_to].freeze

    def index
      render json: Search.search(
        first(:q, "").to_s,
        search_filters,
        limit: int_param(:limit, 25),
        offset: int_param(:offset, 0),
        expand: bool_param(:expand, true),
        summarize: bool_param(:summarize, true)
      )
    end

    private

    # _search_filters: blank values are dropped so "?ticker=" means no filter.
    def search_filters
      filters = {}
      MULTI_FILTERS.each do |key|
        values = (query[key] || []).reject(&:empty?)
        filters[key.to_sym] = values if values.any?
      end
      SINGLE_FILTERS.each do |key|
        value = first(key)
        filters[key.to_sym] = value if value.present?
      end
      filters
    end
  end
end
