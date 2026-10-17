# frozen_string_literal: true

# Slide edits from the pitch-book page. Editing a title or subtitle pins the
# slide so a rebuild keeps the wording; "Unpin" (pin=0 with no edits) hands the
# slide back to the generator.
class SlidesController < ApplicationController
  def update
    slide = Slide.find(params[:id])
    attrs = params.fetch(:slide, {}).permit(:title, :subtitle, :pin)
    pin = attrs.key?(:pin) ? ActiveModel::Type::Boolean.new.cast(attrs[:pin]) : nil
    Pitchbooks.update_slide!(
      slide,
      # A cleared title would leave the slide unnamed; keep the old one.
      title: attrs[:title].presence,
      subtitle: attrs.key?(:subtitle) ? attrs[:subtitle].to_s : nil,
      pin: pin
    )
    message = slide.is_pinned ? "Slide saved and pinned: a rebuild keeps it." : "Slide unpinned: the next rebuild regenerates it."
    redirect_to pitchbook_path(slide.pitchbook_id, anchor: "edit-slide-#{slide.id}"), notice: message, status: :see_other
  rescue ActiveRecord::RecordInvalid => e
    redirect_to pitchbook_path(slide.pitchbook_id), alert: e.record.errors.full_messages.to_sentence, status: :see_other
  end
end
