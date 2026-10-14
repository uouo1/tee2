# frozen_string_literal: true

require "zip"

module Exporters
  module Pptx
    # The OPC package: every part a PowerPoint file needs, zipped with rubyzip.
    #
    # The fixed parts (presentation properties, one slide master with one blank
    # layout, a theme, the table-style stub) are the smallest set PowerPoint
    # opens without repair; python-pptx ships its default template's eleven
    # layouts, but every slide in this deck uses the blank one, so one is
    # enough. Slides and charts are numbered in the order they are added, and
    # [Content_Types].xml and the relationship parts are derived from that list
    # so nothing can fall out of sync.
    class Package
      include Xml

      SLIDE_W = (13.333 * 914_400).to_i # widescreen 13.333in x 7.5in, as the Python sets prs.slide_width
      SLIDE_H = (7.5 * 914_400).to_i

      CT = {
        presentation: "application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml",
        slide: "application/vnd.openxmlformats-officedocument.presentationml.slide+xml",
        layout: "application/vnd.openxmlformats-officedocument.presentationml.slideLayout+xml",
        master: "application/vnd.openxmlformats-officedocument.presentationml.slideMaster+xml",
        pres_props: "application/vnd.openxmlformats-officedocument.presentationml.presProps+xml",
        view_props: "application/vnd.openxmlformats-officedocument.presentationml.viewProps+xml",
        table_styles: "application/vnd.openxmlformats-officedocument.presentationml.tableStyles+xml",
        theme: "application/vnd.openxmlformats-officedocument.theme+xml",
        chart: "application/vnd.openxmlformats-officedocument.drawingml.chart+xml",
        xlsx: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        app: "application/vnd.openxmlformats-officedocument.extended-properties+xml",
        core: "application/vnd.openxmlformats-package.core-properties+xml",
        rels: "application/vnd.openxmlformats-package.relationships+xml"
      }.freeze

      # Relationship ids 1-5 in presentation.xml.rels are the fixed parts;
      # slides follow from rId6.
      FIRST_SLIDE_RID = 6
      FIRST_SLIDE_ID = 256 # PowerPoint's own numbering for p:sldId; must be >= 256

      attr_reader :title, :slides, :charts

      def initialize(title: "", theme_colors: {})
        @title = title.to_s
        @theme_colors = theme_colors
        @slides = []
        @charts = []
      end

      def add_slide
        slide = SlideXml.new(self, slides.size + 1)
        slides << slide
        slide
      end

      # Returns the 1-based chart number used in part names.
      def add_chart(chart)
        charts << chart
        charts.size
      end

      # Every part by zip entry name, in the order they are written.
      def parts
        parts = {
          "[Content_Types].xml" => content_types_xml,
          "_rels/.rels" => root_rels_xml,
          "docProps/core.xml" => core_xml,
          "docProps/app.xml" => app_xml,
          "ppt/presentation.xml" => presentation_xml,
          "ppt/_rels/presentation.xml.rels" => presentation_rels_xml,
          "ppt/presProps.xml" => pres_props_xml,
          "ppt/viewProps.xml" => view_props_xml,
          "ppt/tableStyles.xml" => table_styles_xml,
          "ppt/theme/theme1.xml" => theme_xml,
          "ppt/slideMasters/slideMaster1.xml" => master_xml,
          "ppt/slideMasters/_rels/slideMaster1.xml.rels" => master_rels_xml,
          "ppt/slideLayouts/slideLayout1.xml" => layout_xml,
          "ppt/slideLayouts/_rels/slideLayout1.xml.rels" => layout_rels_xml
        }
        slides.each do |slide|
          parts[slide.part_name] = slide.to_xml
          parts[slide.rels_name] = slide.rels_xml
        end
        charts.each_with_index do |chart, index|
          number = index + 1
          parts["ppt/charts/chart#{number}.xml"] = chart.to_xml
          parts["ppt/charts/_rels/chart#{number}.xml.rels"] =
            relationships([["rId1", "package", "../embeddings/Microsoft_Excel_Sheet#{number}.xlsx"]])
          parts["ppt/embeddings/Microsoft_Excel_Sheet#{number}.xlsx"] = chart.workbook
        end
        parts
      end

      def save(path)
        Zip::OutputStream.open(path.to_s) do |zip|
          parts.each do |name, bytes|
            zip.put_next_entry(name)
            zip.write(bytes)
          end
        end
        path
      end

      private

      # ------------------------------------------------------------ package

      def content_types_xml
        overrides = {
          "/docProps/app.xml" => CT[:app],
          "/docProps/core.xml" => CT[:core],
          "/ppt/presentation.xml" => CT[:presentation],
          "/ppt/presProps.xml" => CT[:pres_props],
          "/ppt/viewProps.xml" => CT[:view_props],
          "/ppt/tableStyles.xml" => CT[:table_styles],
          "/ppt/theme/theme1.xml" => CT[:theme],
          "/ppt/slideMasters/slideMaster1.xml" => CT[:master],
          "/ppt/slideLayouts/slideLayout1.xml" => CT[:layout]
        }
        slides.each { |slide| overrides["/#{slide.part_name}"] = CT[:slide] }
        charts.each_index { |index| overrides["/ppt/charts/chart#{index + 1}.xml"] = CT[:chart] }
        body = %(<Default Extension="rels" ContentType="#{CT[:rels]}"/><Default Extension="xml" ContentType="application/xml"/>) +
          %(<Default Extension="xlsx" ContentType="#{CT[:xlsx]}"/>) +
          overrides.map { |name, type| %(<Override PartName="#{name}" ContentType="#{type}"/>) }.join
        declare(%(<Types xmlns="#{NS_CONTENT_TYPES}">#{body}</Types>))
      end

      def root_rels_xml
        relationships([
          ["rId1", "officeDocument", "ppt/presentation.xml"],
          ["rId2", "http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties", "docProps/core.xml"],
          ["rId3", "extended-properties", "docProps/app.xml"]
        ])
      end

      def core_xml
        stamp = Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ")
        declare(
          %(<cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" ) +
          %(xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" ) +
          %(xmlns:dcmitype="http://purl.org/dc/dcmitype/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">) +
          %(<dc:title>#{esc(title)}</dc:title><dc:creator>Argos</dc:creator><cp:lastModifiedBy>Argos</cp:lastModifiedBy><cp:revision>1</cp:revision>) +
          %(<dcterms:created xsi:type="dcterms:W3CDTF">#{stamp}</dcterms:created><dcterms:modified xsi:type="dcterms:W3CDTF">#{stamp}</dcterms:modified>) +
          "</cp:coreProperties>"
        )
      end

      def app_xml
        declare(
          %(<Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties" ) +
          %(xmlns:vt="http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes">) +
          %(<Application>Argos</Application><PresentationFormat>Widescreen</PresentationFormat><Slides>#{slides.size}</Slides>) +
          %(<Notes>0</Notes><HiddenSlides>0</HiddenSlides><ScaleCrop>false</ScaleCrop><LinksUpToDate>false</LinksUpToDate>) +
          %(<SharedDoc>false</SharedDoc><HyperlinksChanged>false</HyperlinksChanged><AppVersion>16.0000</AppVersion></Properties>)
        )
      end

      # ------------------------------------------------------- presentation

      def presentation_xml
        slide_ids = slides.each_index.map do |index|
          %(<p:sldId id="#{FIRST_SLIDE_ID + index}" r:id="rId#{FIRST_SLIDE_RID + index}"/>)
        end.join
        declare(
          %(<p:presentation xmlns:a="#{NS_A}" xmlns:r="#{NS_R}" xmlns:p="#{NS_P}" saveSubsetFonts="1" autoCompressPictures="0">) +
          %(<p:sldMasterIdLst><p:sldMasterId id="2147483648" r:id="rId1"/></p:sldMasterIdLst>) +
          %(<p:sldIdLst>#{slide_ids}</p:sldIdLst>) +
          %(<p:sldSz cx="#{SLIDE_W}" cy="#{SLIDE_H}"/><p:notesSz cx="6858000" cy="9144000"/>) +
          %(<p:defaultTextStyle>#{default_text_style_xml}</p:defaultTextStyle></p:presentation>)
        )
      end

      def presentation_rels_xml
        rows = [
          ["rId1", "slideMaster", "slideMasters/slideMaster1.xml"],
          ["rId2", "presProps", "presProps.xml"],
          ["rId3", "viewProps", "viewProps.xml"],
          ["rId4", "theme", "theme/theme1.xml"],
          ["rId5", "tableStyles", "tableStyles.xml"]
        ]
        slides.each_with_index do |slide, index|
          rows << ["rId#{FIRST_SLIDE_RID + index}", "slide", "slides/slide#{slide.number}.xml"]
        end
        relationships(rows)
      end

      # Nine outline levels at 18pt in the minor font, indented half an inch per
      # level — the default PowerPoint writes, and what text boxes inherit.
      def default_text_style_xml
        levels = (1..9).map do |level|
          %(<a:lvl#{level}pPr marL="#{(level - 1) * 457_200}" algn="l" defTabSz="914400" rtl="0" eaLnBrk="1" latinLnBrk="0" hangingPunct="1">) +
            %(<a:defRPr sz="1800" kern="1200"><a:solidFill><a:schemeClr val="tx1"/></a:solidFill>) +
            %(<a:latin typeface="+mn-lt"/><a:ea typeface="+mn-ea"/><a:cs typeface="+mn-cs"/></a:defRPr></a:lvl#{level}pPr>)
        end.join
        %(<a:defPPr><a:defRPr lang="en-US"/></a:defPPr>#{levels})
      end

      def pres_props_xml
        declare(%(<p:presentationPr xmlns:a="#{NS_A}" xmlns:r="#{NS_R}" xmlns:p="#{NS_P}"/>))
      end

      def view_props_xml
        declare(
          %(<p:viewPr xmlns:a="#{NS_A}" xmlns:r="#{NS_R}" xmlns:p="#{NS_P}">) +
          %(<p:normalViewPr><p:restoredLeft sz="15620"/><p:restoredTop sz="94660"/></p:normalViewPr>) +
          %(<p:slideViewPr><p:cSldViewPr><p:cViewPr varScale="1"><p:scale><a:sx n="100" d="100"/><a:sy n="100" d="100"/></p:scale>) +
          %(<p:origin x="0" y="0"/></p:cViewPr></p:cSldViewPr></p:slideViewPr><p:gridSpacing cx="76200" cy="76200"/></p:viewPr>)
        )
      end

      # Only names the default style; the definitions are PowerPoint built-ins.
      def table_styles_xml
        declare(%(<a:tblStyleLst xmlns:a="#{NS_A}" def="#{SlideXml::TABLE_STYLE_ID}"/>))
      end

      # ------------------------------------------------- master, layout, theme

      def master_xml
        declare(
          %(<p:sldMaster xmlns:a="#{NS_A}" xmlns:r="#{NS_R}" xmlns:p="#{NS_P}"><p:cSld>) +
          %(<p:bg><p:bgRef idx="1001"><a:schemeClr val="bg1"/></p:bgRef></p:bg>) +
          %(<p:spTree>#{group_shape_properties_xml}</p:spTree></p:cSld>) +
          %(<p:clrMap bg1="lt1" tx1="dk1" bg2="lt2" tx2="dk2" accent1="accent1" accent2="accent2" accent3="accent3" ) +
          %(accent4="accent4" accent5="accent5" accent6="accent6" hlink="hlink" folHlink="folHlink"/>) +
          %(<p:sldLayoutIdLst><p:sldLayoutId id="2147483649" r:id="rId1"/></p:sldLayoutIdLst>) +
          %(<p:txStyles>#{text_styles_xml}</p:txStyles></p:sldMaster>)
        )
      end

      def master_rels_xml
        relationships([
          ["rId1", "slideLayout", "../slideLayouts/slideLayout1.xml"],
          ["rId2", "theme", "../theme/theme1.xml"]
        ])
      end

      # The one layout every slide uses: python-pptx's `slide_layouts[6]`, Blank.
      def layout_xml
        declare(
          %(<p:sldLayout xmlns:a="#{NS_A}" xmlns:r="#{NS_R}" xmlns:p="#{NS_P}" type="blank" preserve="1">) +
          %(<p:cSld name="Blank"><p:spTree>#{group_shape_properties_xml}</p:spTree></p:cSld>) +
          %(<p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sldLayout>)
        )
      end

      def layout_rels_xml
        relationships([["rId1", "slideMaster", "../slideMasters/slideMaster1.xml"]])
      end

      def group_shape_properties_xml
        %(<p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>) +
          %(<p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr>)
      end

      # Title, body and "other" styles are required by the schema; text boxes
      # and table cells inherit from otherStyle, so it carries the real default.
      def text_styles_xml
        run = %(<a:solidFill><a:schemeClr val="tx1"/></a:solidFill><a:latin typeface="+mn-lt"/><a:ea typeface="+mn-ea"/><a:cs typeface="+mn-cs"/>)
        %(<p:titleStyle><a:lvl1pPr algn="l" defTabSz="914400" rtl="0" eaLnBrk="1" latinLnBrk="0" hangingPunct="1">) +
          %(<a:defRPr sz="4400" kern="1200"><a:solidFill><a:schemeClr val="tx1"/></a:solidFill><a:latin typeface="+mj-lt"/><a:ea typeface="+mj-ea"/><a:cs typeface="+mj-cs"/></a:defRPr></a:lvl1pPr></p:titleStyle>) +
          %(<p:bodyStyle><a:lvl1pPr marL="0" indent="0" algn="l" defTabSz="914400" rtl="0" eaLnBrk="1" latinLnBrk="0" hangingPunct="1">) +
          %(<a:buNone/><a:defRPr sz="1800" kern="1200">#{run}</a:defRPr></a:lvl1pPr></p:bodyStyle>) +
          %(<p:otherStyle><a:defPPr><a:defRPr lang="en-US"/></a:defPPr>) +
          %(<a:lvl1pPr marL="0" algn="l" defTabSz="914400" rtl="0" eaLnBrk="1" latinLnBrk="0" hangingPunct="1"><a:defRPr sz="1800" kern="1200">#{run}</a:defRPr></a:lvl1pPr>) +
          %(</p:otherStyle>)
      end

      # A theme in the deck's own palette so anything that falls back to scheme
      # colours (the built-in table style's accent1 header band) stays on
      # brand. Three entries per format list is the schema minimum; the effect
      # styles are deliberately empty so autoshapes get no drop shadow.
      def theme_xml
        c = @theme_colors
        scheme = {
          dk1: c.fetch(:dk1, "0B0B0B"), lt1: c.fetch(:lt1, "FFFFFF"),
          dk2: c.fetch(:dk2, "52514E"), lt2: c.fetch(:lt2, "F9F9F7"),
          accent1: c.fetch(:accent1, "2A78D6"), accent2: c.fetch(:accent2, "EB6834"),
          accent3: c.fetch(:accent3, "1BAF7A"), accent4: c.fetch(:accent4, "EDA100"),
          accent5: c.fetch(:accent5, "E87BA4"), accent6: c.fetch(:accent6, "008300"),
          hlink: c.fetch(:hlink, "2A78D6"), folHlink: c.fetch(:folHlink, "898781")
        }
        colours = scheme.map { |name, hex| %(<a:#{name}><a:srgbClr val="#{hex}"/></a:#{name}>) }.join
        fonts = %(<a:latin typeface="Calibri"/><a:ea typeface=""/><a:cs typeface=""/>)
        solid = %(<a:solidFill><a:schemeClr val="phClr"/></a:solidFill>)
        lines = [9_525, 25_400, 38_100].map do |w|
          %(<a:ln w="#{w}" cap="flat" cmpd="sng" algn="ctr">#{solid}<a:prstDash val="solid"/></a:ln>)
        end.join
        effects = %(<a:effectStyle><a:effectLst/></a:effectStyle>) * 3
        declare(
          %(<a:theme xmlns:a="#{NS_A}" name="Argos"><a:themeElements>) +
          %(<a:clrScheme name="Argos">#{colours}</a:clrScheme>) +
          %(<a:fontScheme name="Argos"><a:majorFont>#{fonts}</a:majorFont><a:minorFont>#{fonts}</a:minorFont></a:fontScheme>) +
          %(<a:fmtScheme name="Argos"><a:fillStyleLst>#{solid * 3}</a:fillStyleLst><a:lnStyleLst>#{lines}</a:lnStyleLst>) +
          %(<a:effectStyleLst>#{effects}</a:effectStyleLst><a:bgFillStyleLst>#{solid * 3}</a:bgFillStyleLst></a:fmtScheme>) +
          %(</a:themeElements><a:objectDefaults/><a:extraClrSchemeLst/></a:theme>)
        )
      end
    end
  end
end
