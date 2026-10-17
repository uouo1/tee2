# frozen_string_literal: true

require "pathname"

# Deck exporters. Each renders the same slide payloads to a different medium:
# Exporters::Html (the deck partials, self-contained), Exporters::Pdf (Prawn)
# and Exporters::Pptx (OOXML). Port of argos/exporters/__init__.py.
#
# Every exporter takes any object with #title and #slides whose slides respond
# to #kind, #title, #subtitle and #payload_hash — a Pitchbook, or a fixture.
module Exporters
  FORMATS = %w[html pptx pdf].freeze

  module_function

  # Which export formats this install can produce. HTML needs nothing beyond
  # Rails; PDF and PPTX need their gems (prawn, rubyzip), so the UI can hide
  # what it cannot deliver.
  def available_formats
    {
      html: true,
      pptx: loadable?("Exporters::Pptx"),
      pdf: loadable?("Exporters::Pdf")
    }
  end

  # Write `deck` in `format` (html | pptx | pdf) to `path`, defaulting to
  # export_dir/<title>-<id>.<format>. Raises ArgumentError for an unknown
  # format. Returns the Pathname written.
  def export(deck, format, path = nil)
    fmt = format.to_s.downcase
    raise ArgumentError, "unsupported export format: #{format}" unless FORMATS.include?(fmt)

    path = Pathname(path || export_dir.join(filename_for(deck, fmt)))
    case fmt
    when "html" then Html.write(deck, path)
    when "pptx" then Pptx.write(deck, path)
    when "pdf" then Pdf.write(deck, path)
    end
    path
  end

  # Where exports land. Tests write under tmp/ so a test run never leaves files
  # in data/exports (RAILS_PORT.md item 10); ARGOS_EXPORT_DIR overrides both.
  def export_dir
    override = ENV["ARGOS_EXPORT_DIR"].presence
    return Pathname(override).expand_path(Rails.root) if override

    Rails.env.test? ? Rails.root.join("tmp/exports") : Rails.root.join("data/exports")
  end

  # "Project-Lighthouse-12.pdf": letters, digits, - and _ only, so the name is
  # safe in a path and in a Content-Disposition header.
  def filename_for(deck, format)
    safe = deck.title.to_s.gsub(/[^A-Za-z0-9\-_ ]/, "").strip.tr(" ", "-")
    id = deck.respond_to?(:id) ? deck.id : nil
    "#{safe.presence || 'pitchbook'}#{id ? "-#{id}" : ''}.#{format}"
  end

  def loadable?(name)
    name.constantize
    true
  rescue LoadError, NameError
    false
  end

  private_class_method :loadable?
end
