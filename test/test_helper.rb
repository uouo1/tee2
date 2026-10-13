# frozen_string_literal: true

ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"

# schema.rb cannot express the FTS5 table or its triggers, so recreate them
# (idempotently) once the test schema has loaded.
SearchIndex.ensure!

module ActiveSupport
  class TestCase
    # Run tests in parallel with specified workers
    parallelize(workers: :number_of_processors)

    # Workers each get their own database; the index must exist in each.
    parallelize_setup { |_worker| SearchIndex.ensure! }
  end
end
