# frozen_string_literal: true

module Exporters
  module Pptx
    # Small DrawingML text helpers shared by the slide and chart writers.
    #
    # Everything here is plain string building. The parts python-pptx emits are
    # compact single-line XML, and mirroring that keeps the output diffable
    # against the reference deck; an XML builder library would add nothing but
    # whitespace.
    module Xml
      DECLARATION = %(<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n)

      NS_A = "http://schemas.openxmlformats.org/drawingml/2006/main"
      NS_P = "http://schemas.openxmlformats.org/presentationml/2006/main"
      NS_R = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
      NS_C = "http://schemas.openxmlformats.org/drawingml/2006/chart"
      NS_RELATIONSHIPS = "http://schemas.openxmlformats.org/package/2006/relationships"
      NS_CONTENT_TYPES = "http://schemas.openxmlformats.org/package/2006/content-types"

      REL_TYPE_BASE = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/"

      # Characters XML 1.0 forbids outright. python-pptx escapes them as
      # `_x001B_` (the OOXML convention) rather than dropping them, so the
      # text round-trips; do the same.
      CONTROL_CHARS = /[\x00-\x08\x0B\x0C\x0E-\x1F]/

      module_function

      def declare(xml) = DECLARATION + xml

      # Escape a text node. `encode(xml: :text)` handles & < >, which is all a
      # text node needs; attribute values go through `attr`.
      def esc(text)
        text.to_s.scrub.gsub(CONTROL_CHARS) { |char| format("_x%04X_", char.ord) }.encode(xml: :text)
      end

      # Escape an attribute value (without the surrounding quotes).
      def attr(text)
        text.to_s.scrub.gsub(CONTROL_CHARS) { |char| format("_x%04X_", char.ord) }.encode(xml: :attr)[1..-2]
      end

      # One <a:p>. The Python sets paragraph-level font properties
      # (`para.font.size = Pt(26)`), which python-pptx stores as
      # <a:pPr><a:defRPr .../></a:pPr>; that is what the reference deck shows.
      # PowerPoint itself writes run-level <a:rPr>, and every renderer honours
      # that, so emit both: the paragraph default for structural fidelity and
      # the run properties so the styling cannot be lost.
      #
      # size in points (Pt(9.5) -> sz="950"), space_after in points, colour as
      # six upper-case hex digits, align one of "l" | "ctr" | "r" | nil.
      # A "\n" (or "\v") inside the text becomes <a:br/>, as python-pptx does.
      def paragraph(text: "", size: nil, bold: nil, color: nil, align: nil, space_after: nil)
        props_attrs = +""
        props_attrs << %( sz="#{(size * 100).round}") if size
        props_attrs << %( b="#{bold ? 1 : 0}") unless bold.nil?
        props_children = color ? %(<a:solidFill><a:srgbClr val="#{color}"/></a:solidFill>) : ""
        has_props = !(props_attrs.empty? && props_children.empty?)

        ppr_inner = +""
        ppr_inner << %(<a:spcAft><a:spcPts val="#{(space_after * 100).round}"/></a:spcAft>) if space_after
        ppr_inner << "<a:defRPr#{props_attrs}>#{props_children}</a:defRPr>" if has_props
        ppr_attrs = align ? %( algn="#{align}") : ""
        ppr =
          if ppr_inner.empty?
            ppr_attrs.empty? ? "" : "<a:pPr#{ppr_attrs}/>"
          else
            "<a:pPr#{ppr_attrs}>#{ppr_inner}</a:pPr>"
          end

        rpr = has_props ? "<a:rPr#{props_attrs}>#{props_children}</a:rPr>" : ""
        runs = text.to_s.split(/\n|\v/, -1).each_with_index.map do |chunk, index|
          (index.zero? ? "" : "<a:br/>") + (chunk.empty? ? "" : "<a:r>#{rpr}<a:t>#{esc(chunk)}</a:t></a:r>")
        end.join
        "<a:p>#{ppr}#{runs}</a:p>"
      end

      # A Relationships part from [[id, type_suffix, target], ...]. Package-level
      # relationship types (core properties) carry their full URI; everything
      # else is relative to REL_TYPE_BASE.
      def relationships(rows)
        body = rows.map do |id, type, target|
          uri = type.start_with?("http") ? type : REL_TYPE_BASE + type
          %(<Relationship Id="#{id}" Type="#{uri}" Target="#{attr(target)}"/>)
        end.join
        declare(%(<Relationships xmlns="#{NS_RELATIONSHIPS}">#{body}</Relationships>))
      end
    end
  end
end
