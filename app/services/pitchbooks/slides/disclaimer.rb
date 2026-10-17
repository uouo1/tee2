# frozen_string_literal: true

module Pitchbooks
  module Slides
    module Disclaimer
      module_function

      def build(_ctx)
        { title: "Disclaimer", payload: { body: Pitchbooks::DISCLAIMER } }
      end
    end
  end
end
