# frozen_string_literal: true

# The research page: one GET form, facets as links, a cited summary, results,
# and a reader panel for ?document=ID.
#
# Port of runSearch/renderFacets/renderSummary/renderResults/openDocument in
# argos/static/app.js. The browser kept the query and filters in a `state`
# object; here they live in the URL, so a search is bookmarkable, the back
# button works, and a facet is a link that toggles one parameter.
class ResearchController < ApplicationController
  helper DashboardController::Formatting

  PAGE_SIZE = 25
  # Filters the reference's _search_filters accepted: two repeatable keys and
  # the single-valued rest.
  MULTI_FILTERS = %i[doc_type ticker].freeze
  SINGLE_FILTERS = %i[company sector source author sentiment date_from date_to].freeze

  helper_method :research_params, :toggle_path, :year_path, :year_selected?, :document_path_for, :page_path

  def index
    @query = params[:q].to_s.strip
    # The checkbox is preceded by a hidden expand=0, so an unticked box
    # arrives as "0" and a first visit (no parameter) expands, as before.
    @expand = !%w[0 false no].include?(params.fetch(:expand, "1").to_s.downcase)
    @filters = search_filters
    @offset = [params[:offset].to_i, 0].max
    # An empty query is browse mode (newest first), which is what the
    # reference showed on opening the tab.
    @result = Search.search(@query, @filters, limit: PAGE_SIZE, offset: @offset, expand: @expand)
    @examples = example_queries(Company.order(:ticker).pick(:ticker))
    @pitchbooks = Pitchbook.order(updated_at: :desc).includes(:target_company).to_a

    @active_document_id = params[:document].presence&.to_i
    return unless @active_document_id

    @document = Search.get_document(@active_document_id, query_terms: @query.split)
  end

  private

  # Example chips adapt to whatever corpus is loaded: the ticker-scoped
  # example uses the first company in the database rather than a demo name.
  def example_queries(ticker)
    [
      "pricing pressure",
      '"backlog" OR "order book"',
      "guidance type:press-release",
      "margin -restructuring",
      "tariff OR datacenter",
      "ticker:#{ticker || 'NVG'} cash flow"
    ]
  end

  def search_filters
    filters = {}
    MULTI_FILTERS.each do |key|
      values = Array(params[key]).map { |v| v.to_s.strip }.reject(&:empty?)
      filters[key] = values if values.any?
    end
    SINGLE_FILTERS.each do |key|
      value = params[key].to_s.strip
      filters[key] = value unless value.empty?
    end
    filters
  end

  # The current search as URL parameters, without the reader or paging.
  def research_params
    base = {}
    base[:q] = @query if @query.present?
    base[:expand] = "0" unless @expand
    @filters.each { |key, value| base[key] = value }
    base
  end

  # Link that adds or removes one facet value. doc_type and ticker are
  # multi-select; sentiment is single-valued, so picking another replaces it.
  # Paging and the open document reset, because the result set changes.
  def toggle_path(key, value)
    query = research_params
    value = value.to_s
    if MULTI_FILTERS.include?(key)
      current = Array(query[key])
      query[key] = current.include?(value) ? current - [value] : current + [value]
      query.delete(key) if query[key].empty?
    else
      query[key] == value ? query.delete(key) : query[key] = value
    end
    research_path(query)
  end

  # The year facet is read-only in the index (there is no year filter key),
  # so the reference appended the year to the query. Search now understands a
  # `date:` field (contract item 21), so the link adds "date:2025" — a real
  # date filter rather than the bare number as a search term — and removes it
  # again when the year is already selected.
  def year_path(year)
    token = "date:#{year}"
    terms = @query.split
    terms = terms.include?(token) ? terms - [token] : terms + [token]
    query = research_params.merge(q: terms.join(" "))
    query.delete(:q) if query[:q].empty?
    research_path(query)
  end

  def year_selected?(year)
    @query.split.include?("date:#{year}")
  end

  # Open a document in the reader panel while keeping the search and page.
  def document_path_for(document_id)
    query = research_params.merge(document: document_id)
    query[:offset] = @offset if @offset.positive?
    research_path(query)
  end

  def page_path(offset)
    query = research_params
    query[:offset] = offset if offset.positive?
    research_path(query)
  end
end
