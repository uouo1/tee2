# frozen_string_literal: true

module Pitchbooks
  module Slides
    # Cover: who the deck is for, and the stamp that says which data and which
    # code produced it (RAILS_PORT.md item 22). A deck mailed around for a week
    # must say what it was built from, or nobody can tell a stale figure from a
    # wrong one.
    module Cover
      module_function

      def build(ctx)
        book = ctx.pitchbook
        metrics = ctx.metrics
        {
          title: book.title,
          subtitle: book.subtitle,
          payload: {
            client_name: book.client_name,
            target: metrics[:name],
            ticker: metrics[:ticker],
            banker: book.banker,
            date: Time.now.utc.strftime("%d %B %Y"),
            confidential: true,
            stamp: ctx.stamp
          }
        }
      end
    end
  end
end
