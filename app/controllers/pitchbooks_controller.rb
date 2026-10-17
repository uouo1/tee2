# frozen_string_literal: true

# Pitch-book pages: the deck list with the new-deck form, and one deck with its
# toolbar (export, rebuild, delete), the DCF assumptions form, the comp-set
# chips, the slide editor (title/subtitle edits pin a slide, move up/down), the
# evidence list and the deck preview. Port of renderBook / loadPitchbooks in
# argos/static/app.js, server-rendered: every edit the Python UI reached only
# through the API is a form here (RAILS_PORT.md item 8).
class PitchbooksController < ApplicationController
  before_action :load_pitchbook, except: %i[index create]

  EXPORT_TYPES = {
    "html" => "text/html",
    "pdf" => "application/pdf",
    "pptx" => "application/vnd.openxmlformats-officedocument.presentationml.presentation"
  }.freeze

  def index
    prepare_index
  end

  def create
    attrs = pitchbook_params
    if attrs[:target_ticker].blank?
      @error = "Choose a target company."
      prepare_index
      return render :index, status: :unprocessable_content
    end

    book = Pitchbooks.create!(
      title: attrs[:title].presence || "Project #{attrs[:target_ticker].to_s.upcase}",
      target_ticker: attrs[:target_ticker],
      comp_tickers: Array(attrs[:comp_tickers]).compact_blank,
      client_name: attrs[:client_name],
      subtitle: attrs[:subtitle],
      banker: attrs[:banker]
    )
    redirect_to pitchbook_path(book), notice: "Deck generated with #{book.slides.size} slides.", status: :see_other
  rescue ArgumentError => e
    @error = e.message
    prepare_index
    render :index, status: :unprocessable_content
  end

  def show
    @slides = @pitchbook.slides.to_a
    @comps = @pitchbook.comp_tickers
    @companies = Company.where.not(id: @pitchbook.target_company_id).order(:ticker)
    @formats = Exporters.available_formats.select { |_, ok| ok }.keys.map(&:to_s)
    @warnings = Pitchbooks.staleness(@pitchbook)
    @evidence = Pitchbooks::Slides::EvidenceAppendix.build_for(@pitchbook)[:payload][:items]
    @assumptions = @slides.find { |s| s.kind == "dcf" }&.payload_hash&.dig(:assumptions) || {}
    @overrides = @pitchbook.assumptions_hash
    @deck_html = Exporters::Html.render_body(@pitchbook)
  end

  def destroy
    title = @pitchbook.title
    Pitchbooks.delete!(@pitchbook)
    redirect_to pitchbooks_path, notice: "Deleted “#{title}”.", status: :see_other
  end

  def rebuild
    Pitchbooks.rebuild_slides!(@pitchbook)
    redirect_to pitchbook_path(@pitchbook), notice: "Deck rebuilt from current data.", status: :see_other
  rescue ArgumentError => e
    redirect_to pitchbook_path(@pitchbook), alert: e.message, status: :see_other
  end

  # The comp-set chips post every ticker they want; an empty set is allowed
  # (the hidden blank keeps the parameter present when nothing is checked).
  def comps
    tickers = Array(params[:tickers]).compact_blank.map { |t| t.to_s.upcase }
    Pitchbooks.set_comps!(@pitchbook, tickers)
    redirect_to pitchbook_path(@pitchbook), notice: "Comparables set to #{tickers.join(', ').presence || 'none'}; deck rebuilt.", status: :see_other
  rescue ArgumentError => e
    redirect_to pitchbook_path(@pitchbook), alert: e.message, status: :see_other
  end

  def assumptions
    raw = params.fetch(:assumptions, {}).permit(*Valuation::DcfAssumptions.members).to_h
    Pitchbooks.set_assumptions!(@pitchbook, raw)
    redirect_to pitchbook_path(@pitchbook), notice: "Assumptions applied; valuation slides rebuilt.", status: :see_other
  rescue ArgumentError, TypeError, Date::Error => e
    redirect_to pitchbook_path(@pitchbook), alert: "Assumptions not applied: #{e.message}", status: :see_other
  end

  # Either a full order (slide_ids[]) or one slide moved up/down by one place.
  def reorder
    if params[:slide_ids].present?
      Pitchbooks.reorder_slides!(@pitchbook, Array(params[:slide_ids]))
    elsif params[:slide_id].present? && %w[up down].include?(params[:direction])
      Pitchbooks.move_slide!(@pitchbook, params[:slide_id], params[:direction])
    else
      return redirect_to pitchbook_path(@pitchbook), alert: "Nothing to reorder.", status: :see_other
    end
    redirect_to pitchbook_path(@pitchbook, anchor: params[:slide_id].present? ? "edit-slide-#{params[:slide_id]}" : nil),
                notice: "Slide order saved.", status: :see_other
  end

  # The deck markup alone: the exporter's own partials, for embedding.
  def preview
    render html: Exporters::Html.render_body(@pitchbook).html_safe, layout: false
  end

  # Writes the export under Exporters.export_dir and sends it; `download=0`
  # returns the metadata instead (the Python API's behaviour).
  def export
    fmt = params[:format].to_s.downcase.presence || "html"
    unless Exporters.available_formats[fmt.to_sym]
      return redirect_to pitchbook_path(@pitchbook), alert: "Export format unavailable: #{fmt}", status: :see_other
    end

    path = Exporters.export(@pitchbook, fmt)
    if params[:download] == "0"
      render json: { path: path.to_s, format: fmt, filename: path.basename.to_s, bytes: path.size }
    else
      send_file path, filename: path.basename.to_s, type: EXPORT_TYPES.fetch(fmt), disposition: "attachment"
    end
  end

  private

  def load_pitchbook
    @pitchbook = Pitchbook.includes(:target_company).find(params[:id])
  end

  def pitchbook_params
    params.fetch(:pitchbook, {}).permit(:target_ticker, :title, :client_name, :banker, :subtitle, comp_tickers: [])
  end

  def prepare_index
    @pitchbooks = Pitchbooks.list
    @companies = Company.order(:ticker).to_a
    chosen = params.dig(:pitchbook, :target_ticker).presence || params[:target].presence
    @target = @companies.find { |c| c.ticker == chosen.to_s.upcase }&.ticker || @companies.first&.ticker
    @selected = Array(params.dig(:pitchbook, :comp_tickers)).compact_blank
    @suggested = @target ? Pitchbooks.suggest_comps(@target) : []
    @checked = request.post? && @selected.any? ? @selected : @suggested
    @form = params.fetch(:pitchbook, {}).permit(:title, :client_name, :banker)
  end
end
