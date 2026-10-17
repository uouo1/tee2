# frozen_string_literal: true

module Api
  # Saved searches (get_saved_searches, post_saved_search and
  # delete_saved_search in argos/api.py).
  class SavedSearchesController < BaseController
    def index
      render json: { saved_searches: SavedSearch.order(id: :desc).map { |saved| present(saved) } }
    end

    # The watermark starts at the newest document now in the corpus, so only
    # documents that arrive after saving alert; a client may pass its own
    # last_seen_document_id (0 replays the whole corpus).
    def create
      payload = body_hash
      query_text = payload[:query].to_s
      raise Error, "query is required" if query_text.strip.empty?

      filters = payload[:filters]
      raise Error, "filters must be an object" unless filters.nil? || filters.is_a?(Hash)

      saved = SavedSearch.create!(
        name: payload[:name].presence || query_text[0, 60],
        query: query_text,
        filters: JSON.generate(filters || {}),
        last_seen_document_id: watermark(payload)
      )
      render json: present(saved)
    end

    def destroy
      saved_id = path_int
      SavedSearch.where(id: saved_id).delete_all
      render json: { deleted: saved_id }
    end

    private

    def watermark(payload)
      return Document.maximum(:id) || 0 unless payload.key?(:last_seen_document_id)

      Integer(payload[:last_seen_document_id] || 0)
    rescue ArgumentError, TypeError
      raise Error, "last_seen_document_id must be an integer"
    end

    # The row as stored, with filters decoded: the reference returned the
    # column's JSON text, which every client then had to parse a second time.
    def present(saved)
      saved.attributes.symbolize_keys.merge(filters: saved.filters_hash)
    end
  end
end
