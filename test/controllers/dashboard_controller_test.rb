# frozen_string_literal: true

require "test_helper"

# The landing page, the application shell around every page, and the palette
# stylesheet. Ports tests/test_api.py HttpTests#test_index_and_assets_are_served
# and #test_palette_css_defines_both_schemes to the server-rendered UI.
class DashboardControllerTest < ActionDispatch::IntegrationTest
  self.use_transactional_tests = false

  setup { Seed::Demo.seed! unless Document.exists? }

  test "dashboard renders tiles, both charts, themes, coverage and newest documents" do
    get root_path
    assert_response :success
    assert_select "title", /Argos/
    assert_select "#dashboard-tiles .tile", 5
    assert_select "#dashboard-tiles .tile .label", text: "Documents"
    assert_select "#dashboard-sentiment svg"
    assert_select "#dashboard-volume svg"
    assert_select "#dashboard-coverage tbody tr", Company.count
    assert_select "#dashboard-recent article.result", [Document.count, 8].min
    # "As of" is the newest document date, never today.
    newest = Document.maximum(:published_at).to_s
    assert_includes response.body, "as of #{newest}"
  end

  test "emerging-theme chips link to a phrase search" do
    themes = Analytics.overview[:trending]
    skip "seed corpus produced no trending themes" if themes.empty?

    get root_path
    href = "/research?q=#{CGI.escape(%("#{themes.first[:theme]}"))}"
    assert_select "#dashboard-themes a.chip[href=?]", href
  end

  test "coverage rows link to the company page" do
    get root_path
    ticker = Company.order(:ticker).first.ticker
    assert_select "#dashboard-coverage a[href=?]", "/companies/#{ticker}"
  end

  test "layout carries the nav, the corpus stamp and the theme toggle" do
    get root_path
    assert_select "nav.tabs a.tab", 5
    assert_select "nav.tabs a.tab[aria-current=page]", text: "Dashboard"
    assert_select "#corpus-stamp", /#{Document.count} documents · as of/
    assert_select "button#theme-toggle[data-controller=theme][data-action=?]", "theme#toggle"
    assert_select "link[rel=stylesheet][href=?]", "/tokens.css"
  end

  test "tokens.css defines the light palette and both dark schemes as text/css" do
    get tokens_css_path
    assert_response :success
    assert_includes response.media_type, "text/css"
    body = response.body
    assert body.start_with?(":root {")
    assert_includes body, "prefers-color-scheme: dark"
    assert_includes body, ':root:where(:not([data-theme="light"]))'
    assert_includes body, ':root[data-theme="dark"] {'
    assert_includes body, "--surface-1: #{Charts::PALETTE[:light][:surface]};"
    assert_includes body, "--surface-1: #{Charts::PALETTE[:dark][:surface]};"
    # The dark body is unwrapped from its own selector before re-wrapping.
    assert_equal 1, body.scan(":root {").size
    assert_equal body.count("{"), body.count("}")
  end

  test "an empty corpus renders n/a rather than zero tone" do
    # Mean tone with no documents is unknown; check the formatter the tile uses.
    view = ActionView::Base.empty
    view.extend(DashboardController::Formatting)
    assert_equal "n/a", view.tone(nil)
    assert_equal "n/a", view.money(nil)
    assert_equal "n/a", view.mult(nil)
    assert_equal "n/a", view.pct(nil)
    assert_equal "n/a", view.num(nil)
    assert_equal "+0.00", view.tone(0.0)
    assert_equal "$1.2bn", view.money(1234.0)
    assert_equal "$345m", view.money(345.4)
    assert_equal "12.3x", view.mult(12.34)
    assert_equal "23.1%", view.pct(0.231)
    assert_equal "1.5", view.num(1.5, 2)
    assert_equal "1,235", view.num(1234.6)
  end

  test "stylesheet keeps the app shell and deck-preview rules" do
    css = Rails.root.join("app/assets/stylesheets/application.css").read
    %w[.topbar .tiles .results-layout .summary-card .reader .company-layout .deck-preview .deck-preview\ .slide
       .heat-1 .toast dialog].each do |selector|
      assert_includes css, selector
    end
    # Colours come from /tokens.css; the only literals are the fixed text
    # colours on filled marks, as in the reference stylesheet.
    assert_empty css.scan(/#[0-9a-f]{3,6}\b/i).uniq - %w[#fff #0b0b0b]
  end

  test "the importmap exposes the three Stimulus controllers" do
    get root_path
    importmap = css_select("script[type=importmap]").first.text
    %w[controllers/theme_controller controllers/pin_dialog_controller controllers/comp_picker_controller].each do |name|
      assert_includes importmap, %("#{name}")
    end
    index = Rails.root.join("app/javascript/controllers/index.js").read
    %w[theme pin-dialog comp-picker].each { |name| assert_includes index, "application.register(\"#{name}\"" }
  end

  test "the comp-picker partial pairs each chip with an input enabled only when pressed" do
    html = ApplicationController.render(partial: "shared/comp_picker",
                                        locals: { companies: [%w[NVG NovaGrid], %w[HLDX Helio], %w[VLTR Voltara]],
                                                  target: "NVG", selected: %w[HLDX NVG], target_select: "#book-target" })
    doc = Nokogiri::HTML.fragment(html)
    picker = doc.at_css("[data-controller=comp-picker]")
    assert_equal "#book-target", picker["data-comp-picker-target-select-value"]
    assert doc.at_css("button[data-ticker=NVG]").key?("hidden"), "the target is not its own comp"
    assert_equal "true", doc.at_css("button[data-ticker=HLDX]")["aria-pressed"]
    assert_equal "false", doc.at_css("button[data-ticker=VLTR]")["aria-pressed"]
    enabled = doc.css("input[name='comp_tickers[]']").reject { |input| input.key?("disabled") }.map { |input| input["value"] }
    assert_equal ["HLDX"], enabled
  end
end
