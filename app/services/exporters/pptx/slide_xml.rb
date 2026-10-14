# frozen_string_literal: true

module Exporters
  module Pptx
    # One slide part. Shapes accumulate in the order they are added, using
    # python-pptx's vocabulary and numbering: ids start at 2 because id 1 is the
    # shape tree itself, and a shape is named "<Type> <id - 1>" ("TextBox 1",
    # "Rectangle 2", "Chart 3", "Table 4"). Relationship rId1 is always the blank
    # layout; charts take rId2 onwards.
    class SlideXml
      include Xml

      # "Medium Style 2 - Accent 1", the built-in style python-pptx assigns to
      # every new table. tableStyles.xml only names it; PowerPoint supplies it.
      TABLE_STYLE_ID = "{5C22544A-7EE6-4342-B048-85BDC9FD1C3A}"

      attr_reader :number, :chart_numbers

      def initialize(package, number)
        @package = package
        @number = number
        @shapes = []
        @chart_numbers = []
      end

      def part_name = "ppt/slides/slide#{number}.xml"
      def rels_name = "ppt/slides/_rels/slide#{number}.xml.rels"

      # A text box holding `paragraphs`, each a Hash of Xml.paragraph keywords.
      # `wrap: true` is python-pptx's `word_wrap = True` (wrap="square"); the
      # default text box does not wrap ("none"). Auto-fit grows the box to its
      # text, like python-pptx's default <a:spAutoFit/>.
      def text_box(left, top, width, height, paragraphs, wrap: true)
        id = next_id
        # A text body needs at least one paragraph to be schema-valid.
        body = paragraphs.empty? ? "<a:p/>" : paragraphs.map { |para| paragraph(**para) }.join
        @shapes << (
          %(<p:sp><p:nvSpPr><p:cNvPr id="#{id}" name="TextBox #{id - 1}"/><p:cNvSpPr txBox="1"/><p:nvPr/></p:nvSpPr>) +
          %(<p:spPr>#{xfrm(left, top, width, height)}<a:prstGeom prst="rect"><a:avLst/></a:prstGeom><a:noFill/></p:spPr>) +
          %(<p:txBody><a:bodyPr wrap="#{wrap ? 'square' : 'none'}"><a:spAutoFit/></a:bodyPr><a:lstStyle/>#{body}</p:txBody></p:sp>)
        )
        self
      end

      # A filled rectangle with no outline — the hairline rule under a heading.
      # The <p:style> block is what python-pptx stamps on every autoshape; the
      # explicit solid fill and noFill line override the theme references it
      # points at.
      def rectangle(left, top, width, height, fill:)
        id = next_id
        @shapes << (
          %(<p:sp><p:nvSpPr><p:cNvPr id="#{id}" name="Rectangle #{id - 1}"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr>) +
          %(<p:spPr>#{xfrm(left, top, width, height)}<a:prstGeom prst="rect"><a:avLst/></a:prstGeom>) +
          %(<a:solidFill><a:srgbClr val="#{fill}"/></a:solidFill><a:ln><a:noFill/></a:ln></p:spPr>) +
          %(<p:style><a:lnRef idx="1"><a:schemeClr val="accent1"/></a:lnRef><a:fillRef idx="3"><a:schemeClr val="accent1"/></a:fillRef>) +
          %(<a:effectRef idx="2"><a:schemeClr val="accent1"/></a:effectRef><a:fontRef idx="minor"><a:schemeClr val="lt1"/></a:fontRef></p:style>) +
          %(<p:txBody><a:bodyPr rtlCol="0" anchor="ctr"/><a:lstStyle/><a:p><a:pPr algn="ctr"/></a:p></p:txBody></p:sp>)
        )
        self
      end

      # A table graphic frame. `cells` is a list of rows, each a list of Hashes
      # of Xml.paragraph keywords plus an optional :fill (cell background).
      # Columns share the width equally and rows the height, with the integer
      # remainder going to the last column/row — python-pptx's `new_tbl`.
      def table(left, top, width, height, cells)
        id = next_id
        rows = cells.map(&:dup)
        columns = rows.map(&:size).max || 0
        # Pad ragged rows so the grid stays rectangular (a malformed table
        # makes PowerPoint refuse the whole file).
        rows.each { |row| row.fill({ text: "" }, row.size...columns) }
        col_width = columns.positive? ? width / columns : width
        row_height = rows.empty? ? height : height / rows.size
        grid = Array.new(columns) do |index|
          w = index == columns - 1 ? col_width + (width - col_width * columns) : col_width
          %(<a:gridCol w="#{w}"/>)
        end.join
        body = rows.each_with_index.map do |row, row_index|
          h = row_index == rows.size - 1 ? row_height + (height - row_height * rows.size) : row_height
          %(<a:tr h="#{h}">#{row.map { |cell| cell_xml(cell) }.join}</a:tr>)
        end.join
        @shapes << (
          %(<p:graphicFrame><p:nvGraphicFramePr><p:cNvPr id="#{id}" name="Table #{id - 1}"/>) +
          %(<p:cNvGraphicFramePr><a:graphicFrameLocks noGrp="1"/></p:cNvGraphicFramePr><p:nvPr/></p:nvGraphicFramePr>) +
          %(<p:xfrm><a:off x="#{left}" y="#{top}"/><a:ext cx="#{width}" cy="#{height}"/></p:xfrm>) +
          %(<a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/table">) +
          %(<a:tbl><a:tblPr firstRow="1" bandRow="1"><a:tableStyleId>#{TABLE_STYLE_ID}</a:tableStyleId></a:tblPr>) +
          %(<a:tblGrid>#{grid}</a:tblGrid>#{body}</a:tbl></a:graphicData></a:graphic></p:graphicFrame>)
        )
        self
      end

      # A chart graphic frame. The chart part itself is registered with the
      # package (which numbers it) and linked from this slide's rels.
      def chart(left, top, width, height, chart_xml)
        id = next_id
        @chart_numbers << @package.add_chart(chart_xml)
        rid = "rId#{@chart_numbers.size + 1}"
        @shapes << (
          %(<p:graphicFrame><p:nvGraphicFramePr><p:cNvPr id="#{id}" name="Chart #{id - 1}"/>) +
          %(<p:cNvGraphicFramePr><a:graphicFrameLocks noGrp="1"/></p:cNvGraphicFramePr><p:nvPr/></p:nvGraphicFramePr>) +
          %(<p:xfrm><a:off x="#{left}" y="#{top}"/><a:ext cx="#{width}" cy="#{height}"/></p:xfrm>) +
          %(<a:graphic><a:graphicData uri="#{NS_C}"><c:chart xmlns:c="#{NS_C}" r:id="#{rid}"/></a:graphicData></a:graphic></p:graphicFrame>)
        )
        self
      end

      def to_xml
        declare(
          %(<p:sld xmlns:a="#{NS_A}" xmlns:p="#{NS_P}" xmlns:r="#{NS_R}"><p:cSld><p:spTree>) +
          %(<p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/>) +
          @shapes.join +
          %(</p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sld>)
        )
      end

      def rels_xml
        rows = [["rId1", "slideLayout", "../slideLayouts/slideLayout1.xml"]]
        @chart_numbers.each_with_index do |chart_number, index|
          rows << ["rId#{index + 2}", "chart", "../charts/chart#{chart_number}.xml"]
        end
        relationships(rows)
      end

      private

      def next_id = @shapes.size + 2

      def xfrm(left, top, width, height)
        %(<a:xfrm><a:off x="#{left}" y="#{top}"/><a:ext cx="#{width}" cy="#{height}"/></a:xfrm>)
      end

      def cell_xml(cell)
        fill = cell[:fill]
        props = fill ? %(<a:tcPr><a:solidFill><a:srgbClr val="#{fill}"/></a:solidFill></a:tcPr>) : "<a:tcPr/>"
        %(<a:tc><a:txBody><a:bodyPr/><a:lstStyle/>#{paragraph(**cell.except(:fill))}</a:txBody>#{props}</a:tc>)
      end
    end
  end
end
