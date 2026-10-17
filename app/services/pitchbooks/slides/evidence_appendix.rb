# frozen_string_literal: true

module Pitchbooks
  module Slides
    # Appendix generated from pinned evidence: each quote keeps its document id,
    # so every citation in the deck stays traceable to the corpus.
    module EvidenceAppendix
      module_function

      def build(ctx)
        build_for(ctx.pitchbook)
      end

      def build_for(pitchbook)
        items = Evidence.where(pitchbook_id: pitchbook.id).order(:id)
                        .left_joins(document: :company)
                        .pluck("evidences.id", "evidences.quote", "evidences.note", "evidences.created_at",
                               "evidences.slide_id", "evidences.document_id", "documents.title",
                               "documents.doc_type", "documents.published_at", "documents.source", "companies.ticker")
                        .map do |id, quote, note, created_at, slide_id, document_id, title, doc_type, published_at, source, ticker|
          { id: id, quote: quote, note: note, created_at: created_at, slide_id: slide_id, document_id: document_id,
            title: title, doc_type: doc_type, published_at: published_at, source: source, ticker: ticker }
        end
        {
          title: "Appendix — sources and evidence",
          subtitle: "#{items.size} pinned item(s) from the research corpus",
          payload: { items: items }
        }
      end
    end
  end
end
