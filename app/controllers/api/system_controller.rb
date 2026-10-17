# frozen_string_literal: true

module Api
  # Liveness and capabilities: health and export-formats in argos/api.py.
  class SystemController < BaseController
    # Status, corpus size and which export formats this install can produce,
    # so a client can hide a format whose gem is missing.
    def health
      render json: {
        status: "ok",
        time: Time.now.utc.iso8601,
        documents: Document.count,
        export_formats: Exporters.available_formats
      }
    end

    def export_formats
      render json: { formats: Exporters.available_formats }
    end
  end
end
