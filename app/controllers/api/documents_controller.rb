# frozen_string_literal: true

module Api
  # GET /api/documents/:id — get_document in argos/api.py.
  class DocumentsController < BaseController
    # `q` carries the query that led here, so the summary and highlights
    # favour the passages the analyst searched for.
    def show
      id = path_int
      document = Search.get_document(id, query_terms: first(:q, "").to_s.split)
      raise Error.new("document #{id} not found", 404) unless document

      render json: document
    end
  end
end
