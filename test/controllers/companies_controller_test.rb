# frozen_string_literal: true

require "test_helper"

# companies#pitchbook calls Pitchbooks.create!, owned by the pitch-book port.
# The tests stub it; this stand-in exists only so they can run before that
# module lands (Object.const_defined? lets Zeitwerk load the real one first).
unless Object.const_defined?(:Pitchbooks)
  module Pitchbooks
    def self.create!(**) = raise(NotImplementedError, "Pitchbooks not ported yet")
  end
end

# Company list and company page. Ports tests/test_api.py
# HandlerTests#test_company_profile_and_charts (profile by ticker in any case,
# the four charts) and adds the audit's labelling requirements
# (docs/RAILS_PORT.md items 2, 3, 11, 12, 17 and 20): basis labels beside every
# multiple, the EV bridge with its balance-sheet date and form, the debt note,
# NTM multiples and the derived-EBITDA flag, the share-count source, KPI
# periods and the segment/table flag, LTM and estimate rows in the
# financials, and n/a — never 0 — for anything unknown.
class CompaniesControllerTest < ActionDispatch::IntegrationTest
  self.use_transactional_tests = false

  # Minitest 6 dropped minitest/mock: swap a module function for the block's
  # duration and put the original back. A non-callable value is returned as is.
  def with_stub(target, name, value)
    original = target.method(name)
    replacement = value.respond_to?(:call) ? value : ->(*_args, **_kwargs) { value }
    target.define_singleton_method(name) { |*args, **kwargs, &block| replacement.call(*args, **kwargs, &block) }
    yield
  ensure
    target.singleton_class.send(:remove_method, name)
    target.define_singleton_method(name, original) unless target.respond_to?(name)
  end

  setup do
    Seed::Demo.seed! unless Document.exists?
    @company = Company.find_ticker("NVG")
    @market = @company.market_datum
    @market_snapshot = @market.attributes.except("id")
    @created_financials = []
    @touched_financials = {}
    @created_companies = []
    @created_books = []
  end

  teardown do
    @market.reload.update_columns(@market_snapshot.except("company_id"))
    Financial.where(id: @created_financials).delete_all
    @touched_financials.each { |id, attrs| Financial.where(id: id).update_all(attrs) }
    Pitchbook.where(id: @created_books).destroy_all
    @created_companies.each do |company|
      Financial.where(company_id: company.id).delete_all
      company.destroy
    end
  end

  test "index lists every company with links" do
    get companies_path
    assert_response :success
    assert_select "#company-list a.company-item", Company.count
    Company.find_each { |company| assert_select "#company-detail a[href=?]", "/companies/#{company.ticker}" }
    assert_select "nav.tabs a.tab[aria-current=page]", text: "Companies"
  end

  test "a company page resolves the ticker in any case and draws the four charts" do
    get company_path("nvg")
    assert_response :success
    assert_select "h1", text: "#{@company.name} (NVG)"
    assert_select "#company-list a.company-item[aria-pressed=true]", 1
    assert_select ".chart-slot", 4
    assert_select ".chart-slot svg", minimum: 3
    assert_select ".tiles .tile", minimum: 5
  end

  test "every multiple carries its basis label and the EBITDA definition" do
    metrics = Valuation.company_metrics("NVG")
    label = metrics[:basis_label]
    get company_path("NVG")
    assert_select ".tile .label .basis", text: label, minimum: 2
    assert_select "#multiples tbody tr.is-highlight td", text: /#{label}/
    assert_select "#multiples .footnote", /GAAP operating income plus depreciation and amortisation, with no adjustments/
    assert_select "#multiples .footnote", /at the price of #{@market.as_of}/
  end

  test "NTM multiples are shown, and a derived EBITDA is flagged" do
    metrics = Valuation.company_metrics("NVG")
    skip "seed has no NTM basis" unless metrics[:ntm]

    get company_path("NVG")
    assert_select ".tile .label .basis", text: "NTM"
    assert_select "#multiples tbody td", text: /\ANTM/
    assert_select "#multiples .footnote", /NTM blends FY#{metrics[:ntm][:fiscal_years].first}/

    derived = metrics[:ntm].merge(ebitda_derived: true)
    with_stub(Valuation, :company_metrics, ->(*_args, **_kw) { metrics.merge(ntm: derived) }) do
      get company_path("NVG")
    end
    assert_select ".tile", text: /EBITDA derived at current margin/
    assert_select "#multiples .basis", text: "EBITDA derived at current margin"
  end

  test "the EV bridge shows the balance-sheet date and form, minority interest, preferred equity and the debt note" do
    @market.update_columns(net_debt_as_of: Date.new(2026, 6, 30), balance_sheet_form: "10-Q",
                           minority_interest: 12.6, preferred_equity: nil,
                           debt_note: "No debt line was reported; bridged at zero debt.")
    get company_path("NVG")
    assert_select "#ev-bridge td", text: /balance sheet 2026-06-30, 10-Q/
    assert_select "#ev-bridge tr", text: /Non-controlling interest\s*\$13m/
    # Not reported is unknown, shown as n/a rather than $0m.
    assert_select "#ev-bridge tr", text: /Preferred equity\s*n\/a/
    assert_select "#debt-note", text: "No debt line was reported; bridged at zero debt."
  end

  test "unknown net debt leaves EV and EV multiples as n/a" do
    @market.update_columns(net_debt: nil)
    get company_path("NVG")
    assert_response :success
    assert_select ".tile", text: /EV n\/a/
    assert_select ".tile .label", text: /EV \/ EBITDA/ do |labels|
      labels.each { |label| assert_equal "n/a", label.parent.at_css(".value").text.strip }
    end
    assert_select "#ev-bridge tr.total", text: /Enterprise value\s*n\/a/
    assert_select "#ev-bridge .footnote", /Net debt is unknown/
    refute_match(/EV \$0m/, response.body)
  end

  test "the share-count source is labelled" do
    @market.update_columns(shares_basic: nil)
    get company_path("NVG")
    assert_select "#ev-bridge td", text: /Cover-page share count/
    assert_select "#share-basis", /cover-page share count/

    @market.update_columns(shares_basic: @market.shares_diluted - 2.5)
    get company_path("NVG")
    assert_select "#ev-bridge td", text: /Diluted weighted-average shares/
    assert_select "#share-basis", /diluted weighted-average count .* not the cover-page count/
  end

  test "financials show FY rows, the LTM row and estimate rows labelled by their source" do
    last_fy = @company.financials.fiscal.where(is_estimate: false).order(:fiscal_year).last
    ltm = @company.financials.create!(fiscal_year: last_fy.fiscal_year, period_type: "LTM",
                                      period_end: Date.new(2026, 6, 30), revenue: 1900.0, ebitda: 480.0,
                                      ebit: 400.0, net_income: nil, eps: 1.5, capex: 60.0)
    @created_financials << ltm.id
    estimate = @company.financials.fiscal.where(is_estimate: true).order(:fiscal_year).first
    @touched_financials[estimate.id] = { estimate_source: estimate.estimate_source }
    estimate.update_columns(estimate_source: "Consensus (12 analysts)")

    get company_path("NVG")
    assert_response :success
    assert_select "#financials tbody tr", @company.financials.count
    assert_select "#financials tr.is-ltm td", text: "LTM Jun-26"
    assert_select "#financials tr.is-ltm td", text: "Trailing twelve months to 2026-06-30"
    # A missing figure is n/a, not 0.
    assert_select "#financials tr.is-ltm td.num", text: "n/a"
    assert_select "#financials tr.is-estimate td", text: "FY#{estimate.fiscal_year}E"
    assert_select "#financials tr.is-estimate td", text: "Consensus (12 analysts)"
    assert_select "#financials tr td", text: "FY#{last_fy.fiscal_year}"
    # Multiples move to the LTM basis and say so.
    assert_select ".tile .label .basis", text: "LTM Jun-26", minimum: 2
    # The chart plots fiscal years only: one bar per year, no duplicate label.
    assert_equal 1, css_select(".chart-slot svg").first.to_s.scan(">FY#{last_fy.fiscal_year}<").size
  end

  test "KPI table shows the period and measure, and flags segment or table figures" do
    buckets = Analytics.kpi_series("NVG")
    refute_empty buckets
    get company_path("NVG")
    assert_select "#kpis tbody tr", buckets.size
    adjusted = buckets.find { |b| b[:measure] == "adjusted" }
    assert_select "#kpis tbody td", text: "adjusted" if adjusted
    assert_select "#kpis tbody td", text: buckets.first[:period].to_s
    assert_select "#kpis .pill.flag", buckets.count { |b| b[:segment_or_table] }

    flagged = buckets.map.with_index { |b, i| i.zero? ? b.merge(segment_or_table: true, latest_context: "Device Solutions segment") : b }
    with_stub(Analytics, :kpi_series, flagged) { get company_path("NVG") }
    assert_select "#kpis .pill.flag", 1
    assert_select "#kpis .pill.flag", text: /not company-level/
  end

  test "theme chips search the theme within the company" do
    themes = Analytics.trending_themes(ticker: "NVG", limit: 8)[:themes]
    skip "no themes for NVG" if themes.empty?

    get company_path("NVG")
    assert_select "a.chip[href=?]", "/research?q=#{CGI.escape(%("#{themes.first[:theme]}" ticker:NVG))}"
  end

  test "documents are listed with links to their pages" do
    get company_path("NVG")
    first = Document.where(company_id: @company.id).newest_first.first
    assert_select "#documents article.result", [Document.where(company_id: @company.id).count, 25].min
    assert_select "#documents a[href=?]", "/documents/#{first.id}"
  end

  test "a company with no quote and no documents renders n/a, not zero" do
    company = Company.create!(ticker: "ZZQT", name: "Quoteless Holdings", sector: "Test")
    @created_companies << company
    company.financials.create!(fiscal_year: 2025, revenue: 100.0, ebitda: nil, eps: nil)
    get company_path("ZZQT")
    assert_response :success
    assert_select ".tile", text: /Share price\s*n\/a\s*no quote loaded/
    assert_select ".tile", text: /Market cap\s*n\/a/
    assert_select ".tile", text: /Corpus tone\s*n\/a/
    refute_match(/\$0\.00/, response.body)
    refute_match(/>\$0m</, response.body)
  end

  test "an unknown company is a 404 page" do
    get company_path("NOPE")
    assert_response :not_found
    assert_select "h1", /Company NOPE not found/
  end

  test "generate deck creates a pitch book through Pitchbooks.create! and opens it" do
    book = Pitchbook.create!(title: "Project NovaGrid", target_company: @company)
    @created_books << book.id
    calls = []
    fake = lambda do |**kwargs|
      calls << kwargs
      book
    end
    with_stub(Pitchbooks, :create!, fake) { post pitchbook_company_path("NVG") }
    assert_redirected_to pitchbook_path(book)
    assert_equal [{ title: "Project NovaGrid", target_ticker: "NVG" }], calls
    assert_equal "Deck generated: Project NovaGrid", flash[:notice]
  end

  test "generate deck reports a failure on the company page" do
    failing = ->(**_kwargs) { raise ArgumentError, "unknown target ticker: NVG" }
    with_stub(Pitchbooks, :create!, failing) { post pitchbook_company_path("NVG") }
    assert_redirected_to company_path("NVG")
    assert_match(/Could not generate a deck/, flash[:alert])
  end

  test "the company page offers the generate-deck button" do
    get company_path("NVG")
    assert_select "form[action=?][method=post] button", "/companies/NVG/pitchbook", text: "Generate deck for NVG"
  end
end
