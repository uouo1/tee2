# frozen_string_literal: true

module Api
  # PATCH/POST /api/slides/:id — edit a slide's title, subtitle or payload
  # (patch_slide in argos/api.py). Editing pins the slide so a rebuild keeps
  # the banker's wording; {"pin": false} edits without pinning or unpins.
  class SlidesController < BaseController
    def update
      id = path_int
      payload = body_hash
      raise Error, "payload must be an object" unless payload[:payload].nil? || payload[:payload].is_a?(Hash)

      slide = Pitchbooks.update_slide!(
        id,
        title: payload[:title],
        subtitle: payload[:subtitle],
        payload: payload[:payload],
        pin: payload[:pin]
      )
      raise Error.new("slide #{id} not found", 404) unless slide

      render json: Pitchbooks.slide_hash(slide)
    end
  end
end
