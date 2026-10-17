# frozen_string_literal: true

module Api
  # DELETE /api/evidence/:id (delete_evidence in argos/api.py). The deck's
  # appendix is refreshed by Pitchbooks.delete_evidence!.
  class EvidencesController < BaseController
    def destroy
      id = path_int
      raise Error.new("evidence #{id} not found", 404) unless Pitchbooks.delete_evidence!(id)

      render json: { deleted: id }
    end
  end
end
