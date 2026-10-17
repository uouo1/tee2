# frozen_string_literal: true

# Save the current research query so the monitor can alert on new matches
# (post_saved_search and delete_saved_search in argos/api.py).
class SavedSearchesController < ApplicationController
  FILTER_KEYS = (ResearchController::MULTI_FILTERS + ResearchController::SINGLE_FILTERS).freeze

  def create
    query = params[:query].to_s.strip
    if query.empty?
      return redirect_to(research_path(research_params), alert: "Type a query first.", status: :see_other)
    end

    SavedSearch.create!(
      name: params[:name].to_s.strip.presence || query[0, 60],
      query: query,
      filters: JSON.generate(saved_filters),
      # Only documents that arrive after saving should alert: start the
      # watermark at the newest document now in the corpus.
      last_seen_document_id: Document.maximum(:id) || 0
    )
    redirect_to research_path(research_params), notice: "Saved. New matches will appear under Monitor.", status: :see_other
  end

  def destroy
    SavedSearch.where(id: params[:id]).delete_all
    redirect_to monitor_path, notice: "Saved search removed.", status: :see_other
  end

  private

  # The research page's filters, kept with the search so alerts run the same
  # query the analyst was looking at.
  def saved_filters
    FILTER_KEYS.each_with_object({}) do |key, filters|
      value = params[key]
      if ResearchController::MULTI_FILTERS.include?(key)
        values = Array(value).map { |v| v.to_s.strip }.reject(&:empty?)
        filters[key] = values if values.any?
      elsif value.present?
        filters[key] = value.to_s.strip
      end
    end
  end

  # Back to the search that was saved.
  def research_params
    back = saved_filters
    back[:q] = params[:query] if params[:query].present?
    back[:expand] = params[:expand] if params[:expand].present?
    back
  end
end
