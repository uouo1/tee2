# frozen_string_literal: true

# Loads the fictional demo corpus (seven grid-software companies, six precedent
# transactions and ~116 documents) so the research index, comps screen and
# valuation models work out of the box. Idempotent: `bin/rails db:seed` can be
# run again at any time; it refreshes company fundamentals and skips documents
# that are already present. Replace it with a real corpus via `argos:ingest[path]`
# or `argos:load_sec[tickers]`.
summary = Seed::Demo.seed!
puts JSON.generate(summary)
