# frozen_string_literal: true

require "stringio"
require "zip"

module Exporters
  module Pptx
    # One native chart part (c:chartSpace) plus the embedded workbook behind it.
    #
    # PowerPoint renders a chart from the string/number caches inside the chart
    # part; the workbook only matters when someone clicks "Edit data". python-pptx
    # always ships one, so a minimal single-sheet .xlsx is written next to each
    # chart to keep the package shaped the way PowerPoint expects.
    #
    # Three shapes cover the deck: clustered columns (revenue, UFCF), a line with
    # markers (margin, tone) and a stacked horizontal bar for the football field,
    # whose first series is transparent so the visible one floats at the low end
    # of each range. Axis styling mirrors `_style_axes` in the Python exporter.
    class ChartXml
      include Xml

      # python-pptx's fixed axis ids per chart template; any unique pair works,
      # these keep the output recognisable against the reference deck.
      AXIS_IDS = {
        column: [-2_068_027_336, -2_113_994_440],
        bar_stacked: [-2_068_027_336, -2_113_994_440],
        line: [2_118_791_784, 2_140_495_176]
      }.freeze

      LINE_WIDTH_EMU = 25_400 # Pt(2), `series.format.line.width` in the Python
      HAIRLINE_EMU = 9_525    # 0.75pt gridline, the "hairline gridlines" rule from charts.py

      attr_reader :kind, :categories, :series

      # series: [{name:, values:, number_format:, fill: "RRGGBB" | :none}, ...]
      def initialize(kind:, categories:, series:, axis_color:, label_color:, grid_color:, gap_width: nil, overlap: nil)
        raise ArgumentError, "unknown chart kind #{kind.inspect}" unless AXIS_IDS.key?(kind)

        @kind = kind
        @categories = categories.map(&:to_s)
        @series = series
        @axis_color = axis_color
        @label_color = label_color
        @grid_color = grid_color
        @gap_width = gap_width
        @overlap = overlap
      end

      def to_xml
        cat_id, val_id = AXIS_IDS.fetch(kind)
        # Horizontal bars put categories on the left and values along the bottom.
        cat_pos, val_pos = kind == :bar_stacked ? %w[l b] : %w[b l]
        declare(
          %(<c:chartSpace xmlns:c="#{NS_C}" xmlns:a="#{NS_A}" xmlns:r="#{NS_R}">) +
          %(<c:date1904 val="0"/><c:chart><c:autoTitleDeleted val="0"/><c:plotArea>) +
          plot_xml(cat_id, val_id) +
          category_axis_xml(cat_id, val_id, cat_pos) +
          value_axis_xml(val_id, cat_id, val_pos) +
          "</c:plotArea>" + chart_tail_xml + "</c:chart>" +
          %(<c:txPr><a:bodyPr/><a:lstStyle/><a:p><a:pPr><a:defRPr sz="1800"/></a:pPr><a:endParaRPr lang="en-US"/></a:p></c:txPr>) +
          %(<c:externalData r:id="rId1"><c:autoUpdate val="0"/></c:externalData></c:chartSpace>)
        )
      end

      # The embedded workbook: categories in column A from row 2, one series per
      # column from B, series names in row 1 — the layout the <c:f> formulas in
      # the caches point at.
      def workbook
        buffer = Zip::OutputStream.write_buffer(StringIO.new(String.new(encoding: Encoding::BINARY))) do |zip|
          workbook_parts.each do |name, xml|
            zip.put_next_entry(name)
            zip.write(xml)
          end
        end
        buffer.string
      end

      private

      def plot_xml(cat_id, val_id)
        sers = series.each_with_index.map { |item, index| series_xml(item, index) }.join
        axes = %(<c:axId val="#{cat_id}"/><c:axId val="#{val_id}"/>)
        case kind
        when :line
          # c:marker turns on the point markers (LINE_MARKERS); c:smooth off keeps
          # straight segments so a tone series is not reinterpreted as a curve.
          %(<c:lineChart><c:grouping val="standard"/><c:varyColors val="0"/>#{sers}<c:marker val="1"/><c:smooth val="0"/>#{axes}</c:lineChart>)
        when :column
          gap = @gap_width ? %(<c:gapWidth val="#{@gap_width}"/>) : ""
          %(<c:barChart><c:barDir val="col"/><c:grouping val="clustered"/>#{sers}#{gap}#{axes}</c:barChart>)
        when :bar_stacked
          overlap = @overlap ? %(<c:overlap val="#{@overlap}"/>) : ""
          %(<c:barChart><c:barDir val="bar"/><c:grouping val="stacked"/>#{sers}#{overlap}#{axes}</c:barChart>)
        end
      end

      def series_xml(item, index)
        column = column_letter(index + 1)
        count = categories.size
        last_row = count + 1
        name = %(<c:tx><c:strRef><c:f>Sheet1!$#{column}$1</c:f><c:strCache><c:ptCount val="1"/><c:pt idx="0"><c:v>#{esc(item[:name])}</c:v></c:pt></c:strCache></c:strRef></c:tx>)
        cat_points = categories.each_with_index.map { |label, idx| %(<c:pt idx="#{idx}"><c:v>#{esc(label)}</c:v></c:pt>) }.join
        cat = %(<c:cat><c:strRef><c:f>Sheet1!$A$2:$A$#{last_row}</c:f><c:strCache><c:ptCount val="#{count}"/>#{cat_points}</c:strCache></c:strRef></c:cat>)
        # A nil value is a gap: ptCount still spans every category but the point
        # is omitted, which is how python-pptx writes None and how PowerPoint
        # reads a blank cell (dispBlanksAs="gap").
        val_points = item[:values].each_with_index.map do |value, idx|
          value.nil? ? "" : %(<c:pt idx="#{idx}"><c:v>#{number_text(value)}</c:v></c:pt>)
        end.join
        val = %(<c:val><c:numRef><c:f>Sheet1!$#{column}$2:$#{column}$#{last_row}</c:f><c:numCache><c:formatCode>#{esc(item[:number_format])}</c:formatCode><c:ptCount val="#{count}"/>#{val_points}</c:numCache></c:numRef></c:val>)
        smooth = kind == :line ? %(<c:smooth val="0"/>) : ""
        %(<c:ser><c:idx val="#{index}"/><c:order val="#{index}"/>#{name}#{series_format_xml(item[:fill])}#{cat}#{val}#{smooth}</c:ser>)
      end

      def series_format_xml(fill)
        if fill == :none
          # The football field's base series: no fill, no outline, so only the
          # span series is visible and appears to float.
          %(<c:spPr><a:noFill/><a:ln><a:noFill/></a:ln></c:spPr>)
        elsif kind == :line
          %(<c:spPr><a:ln w="#{LINE_WIDTH_EMU}"><a:solidFill><a:srgbClr val="#{fill}"/></a:solidFill></a:ln></c:spPr>)
        else
          %(<c:spPr><a:solidFill><a:srgbClr val="#{fill}"/></a:solidFill></c:spPr>)
        end
      end

      def category_axis_xml(id, cross_id, position)
        %(<c:catAx><c:axId val="#{id}"/><c:scaling><c:orientation val="minMax"/></c:scaling><c:delete val="0"/>) +
          %(<c:axPos val="#{position}"/><c:majorTickMark val="out"/><c:minorTickMark val="none"/><c:tickLblPos val="nextTo"/>) +
          axis_style_xml +
          %(<c:crossAx val="#{cross_id}"/><c:crosses val="autoZero"/><c:auto val="1"/><c:lblAlgn val="ctr"/><c:lblOffset val="100"/><c:noMultiLvlLbl val="0"/></c:catAx>)
      end

      def value_axis_xml(id, cross_id, position)
        # Gridlines on the value axis only (`has_major_gridlines = axis is
        # chart.value_axis` in the Python), hairline in the grid token.
        gridlines = %(<c:majorGridlines><c:spPr><a:ln w="#{HAIRLINE_EMU}"><a:solidFill><a:srgbClr val="#{@grid_color}"/></a:solidFill></a:ln></c:spPr></c:majorGridlines>)
        %(<c:valAx><c:axId val="#{id}"/><c:scaling><c:orientation val="minMax"/></c:scaling><c:delete val="0"/>) +
          %(<c:axPos val="#{position}"/>#{gridlines}<c:majorTickMark val="out"/><c:minorTickMark val="none"/><c:tickLblPos val="nextTo"/>) +
          axis_style_xml +
          %(<c:crossAx val="#{cross_id}"/><c:crosses val="autoZero"/></c:valAx>)
      end

      # Tick labels at 10pt in the muted token, axis line in the axis token.
      def axis_style_xml
        %(<c:spPr><a:ln><a:solidFill><a:srgbClr val="#{@axis_color}"/></a:solidFill></a:ln></c:spPr>) +
          %(<c:txPr><a:bodyPr/><a:lstStyle/><a:p><a:pPr><a:defRPr sz="1000"><a:solidFill><a:srgbClr val="#{@label_color}"/></a:solidFill></a:defRPr></a:pPr></a:p></c:txPr>)
      end

      def chart_tail_xml
        if kind == :line
          %(<c:plotVisOnly val="1"/><c:dispBlanksAs val="gap"/><c:showDLblsOverMax val="0"/>)
        else
          %(<c:dispBlanksAs val="gap"/>)
        end
      end

      # Float#to_s is the shortest round-trip form, the same thing Python's
      # repr writes into the cache (2173.3, 42.260000000000005).
      def number_text(value) = Float(value).to_s

      def column_letter(index)
        letters = +""
        n = index
        loop do
          letters.prepend((65 + (n % 26)).chr)
          n = (n / 26) - 1
          break if n.negative?
        end
        letters
      end

      # ----------------------------------------------------------- workbook

      SPREADSHEET_NS = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"

      def workbook_parts
        {
          "[Content_Types].xml" => declare(
            %(<Types xmlns="#{NS_CONTENT_TYPES}">) +
            %(<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>) +
            %(<Default Extension="xml" ContentType="application/xml"/>) +
            %(<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>) +
            %(<Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>) +
            "</Types>"
          ),
          "_rels/.rels" => relationships([["rId1", "officeDocument", "xl/workbook.xml"]]),
          "xl/workbook.xml" => declare(
            %(<workbook xmlns="#{SPREADSHEET_NS}" xmlns:r="#{NS_R}"><sheets><sheet name="Sheet1" sheetId="1" r:id="rId1"/></sheets></workbook>)
          ),
          "xl/_rels/workbook.xml.rels" => relationships([["rId1", "worksheet", "worksheets/sheet1.xml"]]),
          "xl/worksheets/sheet1.xml" => sheet_xml
        }
      end

      def sheet_xml
        rows = []
        header = series.each_with_index.map { |item, index| string_cell("#{column_letter(index + 1)}1", item[:name]) }.join
        rows << %(<row r="1">#{header}</row>)
        categories.each_with_index do |label, row_index|
          row_number = row_index + 2
          cells = [string_cell("A#{row_number}", label)]
          series.each_with_index do |item, index|
            value = item[:values][row_index]
            next if value.nil? # blank cell, matching the gap in the cache

            cells << %(<c r="#{column_letter(index + 1)}#{row_number}"><v>#{number_text(value)}</v></c>)
          end
          rows << %(<row r="#{row_number}">#{cells.join}</row>)
        end
        declare(%(<worksheet xmlns="#{SPREADSHEET_NS}"><sheetData>#{rows.join}</sheetData></worksheet>))
      end

      # Inline strings avoid a shared-strings part; Excel accepts either.
      def string_cell(ref, text) = %(<c r="#{ref}" t="inlineStr"><is><t>#{esc(text)}</t></is></c>)
    end
  end
end
