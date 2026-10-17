# frozen_string_literal: true

# Evidence pinned to a deck: from the research pages' pin dialog (quote with
# document and chunk ids) or typed on the pitch-book page (a note-only item).
# Either way the appendix slide refreshes without a full rebuild.
class EvidencesController < ApplicationController
  def create
    pitchbook = Pitchbook.find(params[:pitchbook_id])
    attrs = params.fetch(:evidence, {}).permit(:quote, :note, :document_id, :chunk_id, :slide_id)
    slide_id = attrs[:slide_id].presence
    slide_id = nil if slide_id && !pitchbook.slides.exists?(id: slide_id)
    Pitchbooks.add_evidence!(
      pitchbook,
      quote: attrs[:quote].to_s,
      document_id: integer_or_nil(attrs[:document_id]),
      chunk_id: integer_or_nil(attrs[:chunk_id]),
      slide_id: slide_id&.to_i,
      note: attrs[:note]
    )
    redirect_back_or_to pitchbook_path(pitchbook, anchor: "evidence"), notice: "Pinned to the deck appendix.", status: :see_other
  rescue ArgumentError => e
    redirect_back_or_to pitchbook_path(pitchbook, anchor: "evidence"), alert: e.message.upcase_first, status: :see_other
  end

  def destroy
    evidence = Evidence.find(params[:id])
    pitchbook_id = evidence.pitchbook_id
    Pitchbooks.delete_evidence!(evidence)
    redirect_to pitchbook_path(pitchbook_id, anchor: "evidence"), notice: "Evidence removed.", status: :see_other
  end

  private

  def integer_or_nil(value)
    Integer(value.to_s, exception: false)
  end
end
