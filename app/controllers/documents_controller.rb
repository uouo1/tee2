# frozen_string_literal: true

# One document on a page of its own: the same reader the research page shows
# beside its results (passages, extracted metrics, similar documents), for
# links from the dashboard, company pages and alerts.
class DocumentsController < ApplicationController
  helper DashboardController::Formatting

  def show
    # Query terms steer the extractive summary towards what was searched for,
    # as the reference's /api/documents/:id?q= did.
    @query = params[:q].to_s
    @document = Search.get_document(params[:id].to_i, query_terms: @query.split)
    return render("shared/not_found", status: :not_found, locals: { what: "Document #{params[:id]}" }) unless @document

    @pitchbooks = Pitchbook.order(updated_at: :desc).includes(:target_company).to_a
  end
end
