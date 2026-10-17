# frozen_string_literal: true

module Api
  # POST /api/ingest and POST /api/seed (post_ingest and post_seed in
  # argos/api.py).
  class IngestController < BaseController
    # {"documents": [...]} (or a bare list) is ingested in one transaction;
    # {"path": "..."} reads a corpus file or directory from disk.
    #
    # A path is resolved with File.expand_path (relative paths against data/)
    # and must stay under Rails.root/data, symlinks followed: the API has no
    # authentication, and the reference would read any file the server could
    # (docs/RAILS_PORT.md item 9).
    def create
      if body.is_a?(Hash) && body[:path].present?
        return render(json: Ingest.ingest_path(corpus_path(body[:path].to_s)))
      end

      documents = body.is_a?(Hash) ? body[:documents] : body
      raise Error, 'expected {"documents": [...]} or {"path": "..."}' unless documents.is_a?(Array) && documents.any?
      raise Error, "each document must be a JSON object" unless documents.all?(Hash)

      begin
        render json: Ingest.ingest_many(documents)
      rescue ArgumentError, ActiveRecord::RecordInvalid => e
        raise Error, e.message
      end
    end

    # Load the synthetic demo dataset (idempotent).
    def seed
      render json: Seed::Demo.seed!
    end

    private

    def data_root
      Rails.root.join("data").to_s
    end

    def corpus_path(raw)
      root = data_root
      expanded = File.expand_path(raw, root)
      raise Error, "path must be inside #{root}" unless inside?(expanded, root)
      raise Error.new("no such path: #{expanded}", 404) unless File.exist?(expanded)
      # The lexical check passes data/link -> /etc; the real path does not.
      real_root = File.exist?(root) ? File.realpath(root) : root
      raise Error, "path must be inside #{root}" unless inside?(File.realpath(expanded), real_root)

      Pathname(expanded)
    end

    # Under the root, not merely sharing its prefix ("data-old/" is outside).
    def inside?(path, root)
      path == root || path.start_with?(root.end_with?("/") ? root : "#{root}/")
    end
  end
end
