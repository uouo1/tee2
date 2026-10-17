# frozen_string_literal: true

module Api
  # Pitch books over JSON: the deck list and lifecycle, comp-set and
  # assumption edits, the valuation behind the deck, its preview and its
  # exports (the pitchbook handlers in argos/api.py and _serve_download in
  # argos/server.py). Every write rebuilds through Pitchbooks, so the API, the
  # web UI and the rake tasks produce the same deck.
  class PitchbooksController < BaseController
    DOWNLOAD_TYPES = {
      "html" => "text/html; charset=utf-8",
      "pptx" => "application/vnd.openxmlformats-officedocument.presentationml.presentation",
      "pdf" => "application/pdf"
    }.freeze
    CURRENCY_SYMBOLS = { "USD" => "$", "EUR" => "€", "GBP" => "£" }.freeze

    def index
      render json: { pitchbooks: Pitchbooks.list, export_formats: Exporters.available_formats }
    end

    # An unknown target is a 404 (the deck's subject does not exist); a
    # missing one is a 400.
    def create
      payload = body_hash
      target = payload[:target_ticker].to_s.strip
      raise Error, "target_ticker is required" if target.empty?

      comps = payload[:comp_tickers]
      raise Error, "comp_tickers must be a list" unless comps.nil? || comps.is_a?(Array)

      book =
        begin
          Pitchbooks.create!(
            title: payload[:title].presence || "Project #{target.upcase}",
            target_ticker: target,
            comp_tickers: comps,
            client_name: payload[:client_name],
            subtitle: payload[:subtitle],
            banker: payload[:banker],
            assumptions: assumptions_payload(payload[:assumptions])
          )
        rescue ArgumentError => e
          raise Error.new(e.message, 404)
        end
      render json: Pitchbooks.detail(book)
    end

    def show
      render json: Pitchbooks.detail(find_book)
    end

    def destroy
      book = find_book
      Pitchbooks.delete!(book)
      render json: { deleted: book.id }
    end

    # Regenerate unpinned slides from current data.
    def rebuild
      book = find_book
      begin
        Pitchbooks.rebuild_slides!(book)
      rescue ArgumentError => e
        raise Error.new(e.message, 404)
      end
      render json: Pitchbooks.detail(book.reload)
    end

    def comps
      book = find_book
      tickers = body_hash[:tickers]
      raise Error, "tickers must be a list" unless tickers.is_a?(Array)

      begin
        Pitchbooks.set_comps!(book, tickers.map(&:to_s))
      rescue ArgumentError => e
        raise Error, e.message
      end
      render json: Pitchbooks.detail(book.reload)
    end

    # Partial DCF overrides; a value the DCF rejects (terminal growth at or
    # above WACC, a stub outside (0, 1]) is a 400 and leaves the deck as it was.
    def assumptions
      book = find_book
      raise Error, "assumptions must be an object" unless body.is_a?(Hash)

      begin
        Pitchbooks.set_assumptions!(book, body)
      rescue ArgumentError, TypeError, Date::Error => e
        raise Error, e.message
      end
      render json: Pitchbooks.detail(book.reload)
    end

    # The football field with everything behind it: ranges (each with
    # in_conclusion, reference and note), comps, precedents, the WACC build,
    # the DCF and its sensitivity, and the concluded range — as Valuation
    # returns them, the target's basis_label included.
    def valuation
      render json: football_field(find_book)
    end

    # The same, pre-rendered as SVG/HTML for the valuation workbench.
    def valuation_charts
      field = football_field(find_book)
      symbol = CURRENCY_SYMBOLS.fetch(field.dig(:target, :currency).presence || "USD", "")
      sensitivity = field[:sensitivity]
      render json: {
        football_field: Charts.football_field_svg(
          field[:ranges], reference_price: field[:reference_price],
                          concluded: field[:concluded_range], currency_symbol: symbol
        ),
        sensitivity: Charts.heatmap_html(
          sensitivity[:grid],
          row_labels: sensitivity[:terminal_axis].map { |g| format("%.2f%%", g * 100) },
          column_labels: sensitivity[:wacc_axis].map { |w| format("%.2f%%", w * 100) },
          row_title: "Terminal growth", column_title: "WACC",
          reference: field[:reference_price]
        ),
        ranges: field[:ranges],
        concluded_range: field[:concluded_range],
        reference_price: field[:reference_price],
        target: field[:target],
        wacc: field[:wacc],
        dcf: field[:dcf],
        dcf_note: field[:dcf_note],
        comps: field[:comps]
      }
    end

    # Deck markup for embedding: the exporter's own partials, so the preview
    # and the exported deck are the same markup.
    def preview
      book = find_book
      render json: { id: book.id, title: book.title, html: Exporters::Html.render_body(book).to_s }
    end

    # Writes the deck under Exporters.export_dir (tmp/exports in tests, never
    # data/) and streams it as an attachment; download=0 returns
    # {path, format, filename, bytes} instead.
    #
    # `format` is read from the query string itself: the API routes pin the
    # Rails format to JSON, which would otherwise shadow ?format=pdf.
    def export
      book = find_book
      fmt = (first(:format, "html").presence || "html").downcase
      formats = Exporters.available_formats.transform_keys(&:to_s)
      raise Error, "export format unavailable: #{fmt}" unless formats[fmt]

      Exporters.export_dir.mkpath
      path = Pathname(Exporters.export(book, fmt))
      if %w[0 false].include?(first(:download, "1"))
        render json: { path: path.to_s, format: fmt, filename: path.basename.to_s, bytes: path.size }
      else
        send_file path.to_s, filename: path.basename.to_s, type: DOWNLOAD_TYPES.fetch(fmt), disposition: "attachment"
      end
    end

    # Pin a passage (or a note) from the research corpus onto the deck.
    def add_evidence
      book = find_book
      payload = body_hash
      evidence =
        begin
          Pitchbooks.add_evidence!(
            book,
            quote: payload[:quote].to_s,
            document_id: payload[:document_id],
            chunk_id: payload[:chunk_id],
            slide_id: payload[:slide_id],
            note: payload[:note]
          )
        rescue ArgumentError, ActiveRecord::InvalidForeignKey, ActiveRecord::RecordInvalid => e
          raise Error, e.message
        end
      render json: evidence.attributes
    end

    # {"slide_ids": [...]} in the new order; the reorder returns every slide.
    def reorder
      book = find_book
      order = body_hash[:slide_ids]
      raise Error, "slide_ids must be a list" unless order.is_a?(Array)

      ids = order.map do |id|
        Integer(id)
      rescue ArgumentError, TypeError
        raise Error, "slide_ids must be integers"
      end
      slides = Pitchbooks.reorder_slides!(book, ids)
      render json: { slides: slides.map { |slide| Pitchbooks.slide_hash(slide) } }
    end

    private

    def find_book
      id = path_int
      Pitchbook.includes(:target_company).find_by(id: id) || raise(Error.new("pitchbook #{id} not found", 404))
    end

    def football_field(book)
      ticker = book.target_company&.ticker
      raise Error, "pitchbook #{book.id} has no target company" unless ticker

      Valuation.football_field(ticker, book.comp_tickers, assumptions: book.assumptions_hash)
    rescue ArgumentError => e
      raise Error, e.message
    end

    def assumptions_payload(value)
      return nil if value.nil?
      raise Error, "assumptions must be an object" unless value.is_a?(Hash)

      value
    end
  end
end
