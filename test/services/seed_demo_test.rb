# frozen_string_literal: true

require "test_helper"

# Seed::Demo has no dedicated Python test module: tests/support.py seeds every
# suite with it and tests/test_cli.py::test_seed_then_stats only checks that
# documents were added. This file pins what every other ported suite relies on:
# the fictional universe (7 companies, 6 deals, 116 documents), the back-cast
# and market derivation formulas (expected numbers taken from argos/seed.py,
# which are RNG-independent), the narrative arc, idempotency and determinism.

module SeedDemoTestHelpers
  REFERENCE_NVG_SERIES = [
    # fiscal_year, is_estimate, revenue, ebitda, ebit, net_income, eps, dep_amort, capex, nwc_change, tax_rate
    [2023, false, 1154.8, 288.7, 228.6, 161.8, 0.89, 60.0, 47.3, 13.9, 0.23],
    [2024, false, 1348.8, 342.6, 272.4, 195.6, 1.07, 70.1, 55.3, 16.2, 0.23],
    [2025, false, 1575.3, 406.4, 324.5, 235.7, 1.29, 81.9, 64.6, 18.9, 0.23],
    [2026, false, 1840.0, 482.1, 386.4, 283.3, 1.56, 95.7, 75.4, 22.1, 0.23],
    [2027, true, 2093.5, 556.9, 448.0, 330.8, 1.82, 108.9, 85.8, 25.1, 0.23],
    [2028, true, 2381.9, 643.1, 519.2, 385.6, 2.12, 123.9, 97.7, 28.6, 0.23]
  ].freeze
  REFERENCE_PRICES = {
    "NVG" => 44.1, "HLDX" => 33.81, "VLTR" => 37.14, "CRGD" => 35.64,
    "PYLN" => 27.8, "TWSW" => 16.19, "MFCL" => 10.15
  }.freeze
  SERIES_KEYS = %i[fiscal_year is_estimate revenue ebitda ebit net_income eps dep_amort capex nwc_change tax_rate].freeze

  # Transactional tests roll back, but the on-disk test database survives a run
  # that was killed half-way and the counts below are absolute, so every
  # database test starts from an empty universe.
  def purge!
    Document.destroy_all
    Company.destroy_all
    Transaction.delete_all
  end

  def fts_match_count(term)
    ActiveRecord::Base.connection.select_value(
      "SELECT COUNT(*) FROM chunks_fts WHERE chunks_fts MATCH #{ActiveRecord::Base.connection.quote(term)}"
    )
  end

  # A company spec the way seed! sees it: fin extended with price/low/high.
  def priced_spec(index = 0, rng: Random.new(1))
    spec = Seed::Demo::COMPANIES[index]
    spec.merge(fin: spec[:fin].merge(Seed::Demo.derive_market(spec, rng)))
  end
end

class SeedDemoTablesTest < ActiveSupport::TestCase
  include SeedDemoTestHelpers

  test "universe constants" do
    assert_equal %w[NVG HLDX VLTR CRGD PYLN TWSW MFCL], Seed::Demo::COMPANIES.map { |c| c[:ticker] }
    assert_equal 6, Seed::Demo::TRANSACTIONS.size
    assert_equal 8, Seed::Demo::PERIODS.size
    assert_equal "FY24 Q3", Seed::Demo::PERIODS.first[0]
    assert_equal Date.new(2026, 7, 23), Seed::Demo::PERIODS.last[1]
    assert_equal [2023, 2024, 2025, 2026, 2027, 2028], Seed::Demo::YEARS
    assert_equal "Grid & Energy Software", Seed::Demo::SECTOR
    assert_equal 4, Seed::Demo::EARLY_THEMES.size
    assert_equal 4, Seed::Demo::LATE_THEMES.size
    assert_equal [7, 6, 7, 5, 3, 4, 6], [
      Seed::Demo::POSITIVE_SENTENCES, Seed::Demo::NEUTRAL_SENTENCES, Seed::Demo::NEGATIVE_SENTENCES,
      Seed::Demo::ANALYST_QUESTIONS, Seed::Demo::RESEARCH_VIEWS, Seed::Demo::NEWS_HEADLINES,
      Seed::Demo::FILING_RISK_FACTORS
    ].map(&:size)
    assert_equal %w[Overweight Neutral Underweight], Seed::Demo::RESEARCH_VIEWS.map(&:first)
    assert Seed::Demo::COMPANIES.frozen? && Seed::Demo::COMPANIES.all?(&:frozen?)
    assert Seed::Demo::COMPANIES.all? { |c| c[:fin].frozen? }
    assert Seed::Demo::TRANSACTIONS.all? { |t| t[:announced_on].is_a?(Date) && t[:sector] == Seed::Demo::SECTOR }
  end

  test "every company spec carries the fields the seeder and generators read" do
    keys = %i[ticker name industry country hq employees description fin tone]
    fin_keys = %i[revenue growth ebitda_margin da_pct capex_pct shares net_debt ev_ebitda_target beta]
    Seed::Demo::COMPANIES.each do |spec|
      assert_equal keys, spec.keys, spec[:ticker]
      assert_equal fin_keys, spec[:fin].keys, spec[:ticker]
      assert_includes(-1.0..1.0, spec[:tone])
    end
  end
end

class SeedDemoFormulaTest < ActiveSupport::TestCase
  include SeedDemoTestHelpers

  test "financial series back-casts and forecasts around the base year exactly like the reference" do
    rows = Seed::Demo.financial_series(Seed::Demo::COMPANIES[0][:fin], Seed::Demo::YEARS)
    assert_equal 6, rows.size
    rows.each { |row| assert_equal SERIES_KEYS, row.keys }
    assert_equal REFERENCE_NVG_SERIES, rows.map(&:values)
  end

  test "financial series spot checks for other companies" do
    mfcl = Seed::Demo.financial_series(Seed::Demo::COMPANIES[6][:fin], Seed::Demo::YEARS).last
    assert_equal [2028, true, 3254.1, 589.0, 367.7, 226.3, 0.73], mfcl.values.first(7)
    pyln = Seed::Demo.financial_series(Seed::Demo::COMPANIES[4][:fin], Seed::Demo::YEARS).first
    assert_equal [2023, false, 268.2, 46.1, 35.4, 27.3, 0.38], pyln.values.first(7)
  end

  test "forecast growth is damped to 82% of trend and margins step 40bps a year" do
    fin = Seed::Demo::COMPANIES[0][:fin]
    rows = Seed::Demo.financial_series(fin, Seed::Demo::YEARS)
    by_year = rows.index_by { |r| r[:fiscal_year] }
    assert_in_delta fin[:revenue] * (1 + fin[:growth] * 0.82), by_year[2027][:revenue], 0.06
    assert_in_delta fin[:revenue] / (1 + fin[:growth]), by_year[2025][:revenue], 0.06
    assert_in_delta fin[:ebitda_margin] + 0.004, by_year[2027][:ebitda] / by_year[2027][:revenue], 0.0002
    assert_in_delta fin[:ebitda_margin] - 0.012, by_year[2023][:ebitda] / by_year[2023][:revenue], 0.0002
  end

  test "net cash companies pay no interest in the net income bridge" do
    pyln = Seed::Demo::COMPANIES[4][:fin] # net_debt -60
    row = Seed::Demo.financial_series(pyln, Seed::Demo::YEARS).find { |r| r[:fiscal_year] == 2026 }
    assert_in_delta row[:ebit] * 0.77, row[:net_income], 0.06
  end

  test "market data is derived from the target EV/EBITDA multiple" do
    Seed::Demo::COMPANIES.each do |spec|
      fin = spec[:fin]
      market = Seed::Demo.derive_market(spec, Random.new(7))
      assert_equal %i[price low high], market.keys
      assert_equal REFERENCE_PRICES[spec[:ticker]], market[:price], spec[:ticker]
      implied = (market[:price] * fin[:shares] + fin[:net_debt]) / (fin[:revenue] * fin[:ebitda_margin])
      assert_in_delta fin[:ev_ebitda_target], implied, 0.01, spec[:ticker]
      assert_includes (market[:price] * 0.68 - 0.01)..(market[:price] * 0.78 + 0.01), market[:low]
      assert_includes (market[:price] * 1.04 - 0.01)..(market[:price] * 1.18 + 0.01), market[:high]
    end
  end

  test "derive_market floors the price at one dollar" do
    spec = { fin: { revenue: 100.0, ebitda_margin: 0.1, ev_ebitda_target: 5.0, net_debt: 900.0, shares: 10.0 } }
    assert_equal 1.0, Seed::Demo.derive_market(spec, Random.new(1))[:price]
  end

  test "derive_market is a pure function of the rng" do
    a = Seed::Demo.derive_market(Seed::Demo::COMPANIES[2], Random.new(42))
    b = Seed::Demo.derive_market(Seed::Demo::COMPANIES[2], Random.new(42))
    assert_equal a, b
    refute_equal a[:low], Seed::Demo.derive_market(Seed::Demo::COMPANIES[2], Random.new(43))[:low]
  end

  test "fy_from_period" do
    assert_equal 2026, Seed::Demo.send(:fy_from_period, "FY26 Q2")
    assert_equal 2024, Seed::Demo.send(:fy_from_period, "FY24 Q3")
  end

  test "fill renders Python-style placeholders" do
    values = { growth: 12.345, wins: 7, theme: "datacenter load growth", unused: 1 }
    assert_equal "Revenue grew 12.3% on 7 wins in datacenter load growth.",
                 Seed::Demo.send(:fill, "Revenue grew {growth:.1f}% on {wins} wins in {theme}.", values)
    assert_equal "$12 million", Seed::Demo.send(:fill, "${growth:.0f} million", values)
    assert_equal "plain", Seed::Demo.send(:fill, "plain", values)
    assert_raises(KeyError) { Seed::Demo.send(:fill, "{missing}", values) }
  end

  test "every placeholder in the banks is a number the generators provide" do
    transcript_keys = %i[growth decline ndr margin bps gm backlog fcf churn wins headcount capex charge theme name]
    (Seed::Demo::POSITIVE_SENTENCES + Seed::Demo::NEUTRAL_SENTENCES + Seed::Demo::NEGATIVE_SENTENCES +
      Seed::Demo::ANALYST_QUESTIONS).each do |sentence|
      sentence.scan(Seed::Demo::PLACEHOLDER_RE) { |name, _| assert_includes transcript_keys, name.to_sym, sentence }
    end
    Seed::Demo::RESEARCH_VIEWS.each do |_, template|
      template.scan(Seed::Demo::PLACEHOLDER_RE) { |name, _| assert_includes %i[name theme growth margin mult], name.to_sym }
    end
    Seed::Demo::NEWS_HEADLINES.flatten.each do |text|
      text.scan(Seed::Demo::PLACEHOLDER_RE) { |name, _| assert_includes %i[name theme sector years], name.to_sym }
    end
  end

  test "title_case follows Python str.title" do
    assert_equal "Tariff Pass-Through On Imported Hardware",
                 Seed::Demo.send(:title_case, "tariff pass-through on imported hardware")
    assert_equal "Legacy Scada Replacement Cycles", Seed::Demo.send(:title_case, "legacy SCADA replacement cycles")
  end
end

class SeedDemoGeneratorsTest < ActiveSupport::TestCase
  include SeedDemoTestHelpers

  SPEAKERS = ["Operator", "Avery Lin, Chief Executive Officer", "Dana Okafor, Chief Financial Officer",
              "Priya Raman, Analyst, Northbank Securities"].freeze

  test "transcript shape and attribution" do
    spec = priced_spec
    doc = Seed::Demo.transcript(Random.new(3), spec, "FY24 Q3", Date.new(2024, 10, 24), "storm hardening programmes", 0.5)
    assert_equal %i[external_id title ticker doc_type source author published_at period body], doc.keys
    assert_equal "NVG-FY24Q3-call", doc[:external_id]
    assert_equal "NovaGrid Systems FY24 Q3 Earnings Call Transcript", doc[:title]
    assert_equal %w[NVG transcript], [doc[:ticker], doc[:doc_type]]
    assert_equal "Company call", doc[:source]
    assert_equal "Investor Relations", doc[:author]
    assert_equal Date.new(2024, 10, 24), doc[:published_at]
    assert_equal "FY24 Q3", doc[:period]
    paragraphs = doc[:body].split("\n\n")
    assert_equal 6, paragraphs.size
    assert_equal [SPEAKERS[0], SPEAKERS[1], SPEAKERS[2], SPEAKERS[3], SPEAKERS[1], SPEAKERS[2]],
                 paragraphs.map { |p| p[/\A[^:]+/] }
    assert_includes paragraphs[0], "NovaGrid Systems FY24 Q3 earnings conference call"
    assert_match(/For the full year we now expect revenue growth in the -?\d+ to -?\d+% range\./, paragraphs[2])
    assert_includes paragraphs[5], "our planning assumption on storm hardening programmes is deliberately"
    refute_match Seed::Demo::PLACEHOLDER_RE, doc[:body]
    # Ingest reads the chunks back with the same speakers.
    assert_equal [SPEAKERS[0], SPEAKERS[1], SPEAKERS[2], SPEAKERS[3], SPEAKERS[1], SPEAKERS[2]],
                 Ingest.chunk_body(doc[:body]).map { |c| c[:speaker] }
  end

  test "transcript tone picks the sentence banks" do
    spec = priced_spec
    positive = Seed::Demo.transcript(Random.new(5), spec, "FY25 Q1", Date.new(2025, 4, 24), "x", 0.8)[:body]
    negative = Seed::Demo.transcript(Random.new(5), spec, "FY25 Q1", Date.new(2025, 4, 24), "x", -0.8)[:body]
    neutral = Seed::Demo.transcript(Random.new(5), spec, "FY25 Q1", Date.new(2025, 4, 24), "x", 0.0)[:body]
    negative_markers = ["pricing pressure in competitive renewals", "Revenue declined", "restructuring charge",
                        "procurement cycles have lengthened", "Deceleration in new logo", "margin compressed",
                        "continued softness"]
    positive_markers = ["ahead of the guidance range", "net dollar retention", "pricing discipline",
                        "Bookings momentum", "raising our full-year outlook", "Free cash flow", "Gross margin reached"]
    assert positive_markers.any? { |m| positive.include?(m) }
    assert negative_markers.none? { |m| positive.include?(m) }, "a positive call must not read from the negative bank"
    assert negative_markers.any? { |m| negative.include?(m) }
    # The analyst answer comes from the negative bank when tone < 0, so no
    # positive sentence can appear anywhere in a negative call.
    assert positive_markers.none? { |m| negative.include?(m) }
    # A neutral call mixes one positive and one negative line into the CEO remarks.
    assert positive_markers.any? { |m| neutral.include?(m) }
    assert negative_markers.any? { |m| neutral.include?(m) }
    assert_operator Nlp.score_sentiment(positive), :>, Nlp.score_sentiment(negative)
  end

  test "transcript numbers are anchored to the company" do
    spec = priced_spec(6) # MFCL: 7320 employees, 3.4% growth
    doc = Seed::Demo.transcript(Random.new(11), spec, "FY26 Q2", Date.new(2026, 7, 23), "datacenter load growth", 0.0)
    if (headcount = doc[:body][/Headcount ended the period at (\d+) employees/, 1])
      assert_includes 7100..7640, headcount.to_i
    end
    # Growth is floored at 1.0 so a low-growth company never "grows" negatively.
    if (growth = doc[:body][/Revenue grew (\d+\.\d)%/, 1])
      assert_operator growth.to_f, :>=, 1.0
    end
    kpis = Nlp.extract_kpis(doc[:body]).map { |k| k[:metric] }
    assert kpis.any?, "the transcript must yield KPIs for the KPI series"
  end

  test "research note rating follows tone" do
    spec = priced_spec
    overweight = Seed::Demo.research_note(Random.new(1), spec, Date.new(2024, 10, 26), "regulatory rate case timing", 0.5)
    neutral = Seed::Demo.research_note(Random.new(1), spec, Date.new(2024, 10, 26), "regulatory rate case timing", 0.0)
    underweight = Seed::Demo.research_note(Random.new(1), spec, Date.new(2024, 10, 26), "regulatory rate case timing", -0.5)
    assert_equal %i[external_id title ticker doc_type source author published_at body], overweight.keys
    assert_equal "NVG-research-2024-10-26", overweight[:external_id]
    assert_equal "NovaGrid Systems (NVG): Overweight — Regulatory Rate Case Timing", overweight[:title]
    assert_equal "NovaGrid Systems (NVG): Neutral — Regulatory Rate Case Timing", neutral[:title]
    assert_equal "NovaGrid Systems (NVG): Underweight — Regulatory Rate Case Timing", underweight[:title]
    assert_equal ["research", "Northbank Securities", "P. Raman"], overweight.values_at(:doc_type, :source, :author)
    assert_match(/\ARating: Overweight\. Price target \$48\./, overweight[:body]) # 44.1 * 1.09
    assert_match(/\ARating: Underweight\. Price target \$40\./, underweight[:body]) # 44.1 * 0.91
    assert_includes overweight[:body], "a premium to the grid & energy software peer median"
    assert_includes neutral[:body], "a discount to the grid & energy software peer median"
    assert_includes neutral[:body], "net retention above 112%."
    assert_includes overweight[:body], "subscription mix of roughly 70% and net debt of $410 million."
    assert_includes underweight[:body], "subscription mix of roughly 50%"
    assert_match(/We value NovaGrid Systems on \d+\.\dx forward EV\/EBITDA/, overweight[:body])
    refute_match Seed::Demo::PLACEHOLDER_RE, overweight[:body]
  end

  test "filing is fully determined by the spec" do
    spec = priced_spec
    doc = Seed::Demo.filing(spec, 2025, Date.new(2026, 2, 14))
    assert_equal %i[external_id title ticker doc_type source published_at body], doc.keys
    assert_equal "NVG-10K-2025", doc[:external_id]
    assert_equal "NovaGrid Systems Annual Report (Form 10-K), FY2025", doc[:title]
    assert_equal ["filing", "Regulatory filing", Date.new(2026, 2, 14)], doc.values_at(:doc_type, :source, :published_at)
    sections = doc[:body].split("\n\n")
    assert_equal 4, sections.size
    assert_equal "Item 1. Business. #{spec[:description]}", sections[0]
    assert_includes sections[1], "Revenue for fiscal 2025 was $1840 million, an increase of 16.8% over the prior year."
    assert_includes sections[1], "Adjusted EBITDA margin was 26.2%. Capex was 4.1% of revenue."
    assert_includes sections[1], "net debt of $410 million and 4280 employees."
    assert_equal "Item 1A. Risk Factors. #{Seed::Demo::FILING_RISK_FACTORS.join(' ')}", sections[2]
    assert_match(/\AItem 7A\./, sections[3])
    assert_equal doc, Seed::Demo.filing(spec, 2025, Date.new(2026, 2, 14))
  end

  test "news quotes the derived market data" do
    spec = priced_spec
    doc = Seed::Demo.news(Random.new(2), spec, Date.new(2025, 2, 14), "storm hardening programmes")
    assert_equal %i[external_id title ticker doc_type source published_at body], doc.keys
    assert_match(/\ANVG-news-2025-02-14-\d{4}\z/, doc[:external_id])
    assert_match(/\ANovaGrid Systems /, doc[:title])
    assert_equal ["news", "Market wire"], doc.values_at(:doc_type, :source)
    low, high = spec[:fin].values_at(:low, :high)
    assert doc[:body].end_with?(
      "NovaGrid Systems trades at $44.10, within a 52-week range of $#{format('%.2f', low)} to $#{format('%.2f', high)}."
    )
    refute_match Seed::Demo::PLACEHOLDER_RE, doc[:body] + doc[:title]
    headlines = (1..40).map { |s| Seed::Demo.news(Random.new(s), spec, Date.new(2025, 2, 14), "storm hardening programmes")[:title] }
    assert_equal 4, headlines.uniq.size, "all four headlines should be drawn over 40 seeds"
  end

  test "expert call has no company" do
    doc = Seed::Demo.expert_call(Random.new(9), Date.new(2026, 3, 5), "interconnection queue backlog")
    assert_equal %i[external_id title doc_type source published_at body], doc.keys
    assert_match(/\Aexpert-2026-03-05-\d{4}\z/, doc[:external_id])
    assert_equal "Expert Call: Utility Procurement and Interconnection Queue Backlog", doc[:title]
    assert_equal ["expert-call", "Expert network"], doc.values_at(:doc_type, :source)
    assert_equal 5, doc[:body].split("\n\n").size
    assert_includes doc[:body], "What has changed in the last year is interconnection queue backlog"
    assert_equal %w[Interviewer Expert Interviewer Expert Interviewer],
                 Ingest.chunk_body(doc[:body]).map { |c| c[:speaker] }
  end
end

class SeedDemoSeedTest < ActiveSupport::TestCase
  include SeedDemoTestHelpers

  setup do
    purge!
    @summary = Seed::Demo.seed!
  end

  test "seeding an empty database yields the demo universe" do
    assert_equal %i[companies transactions documents_added documents_skipped chunks kpis], @summary.keys
    assert_equal 7, @summary[:companies]
    assert_equal 6, @summary[:transactions]
    assert_equal 116, @summary[:documents_added]
    assert_equal 0, @summary[:documents_skipped]
    assert_operator @summary[:documents_added], :>=, 100
    assert_operator @summary[:chunks], :>=, 400
    assert_operator @summary[:kpis], :>, 0
    assert_equal [7, 6, 116], [Company.count, Transaction.count, Document.count]
    assert_equal @summary[:chunks], Chunk.count
    assert_equal @summary[:kpis], Kpi.count
  end

  test "document mix per type" do
    # 8 transcripts, 4 research notes (even periods), 3 news items (idx 1, 4, 7)
    # and 1 filing per company, plus 4 expert calls.
    assert_equal({ "transcript" => 56, "research" => 28, "news" => 21, "filing" => 7, "expert-call" => 4 },
                 Document.group(:doc_type).count)
    assert_equal 116, Document.where.not(external_id: nil).distinct.count(:external_id)
    assert_equal ["expert-call"], Document.where(company_id: nil).distinct.pluck(:doc_type)
    Company.find_each do |company|
      assert_equal({ "transcript" => 8, "research" => 4, "news" => 3, "filing" => 1 },
                   company.documents.group(:doc_type).count, company.ticker)
    end
  end

  test "companies carry the sector and profile fields" do
    Company.find_each do |company|
      spec = Seed::Demo::COMPANIES.find { |c| c[:ticker] == company.ticker }
      assert_equal spec.values_at(:name, :industry, :country, :hq, :employees, :description),
                   [company.name, company.industry, company.country, company.hq, company.employees, company.description]
      assert_equal [Seed::Demo::SECTOR, "USD", false], [company.sector, company.currency, company.is_private]
    end
  end

  test "financials cover six fiscal years with three estimates" do
    nvg = Company.find_ticker("NVG")
    rows = nvg.financials.order(:fiscal_year).map { |f| SERIES_KEYS.map { |k| f.public_send(k) } }
    assert_equal REFERENCE_NVG_SERIES, rows
    assert_equal 42, Financial.count
    assert_equal [2027, 2028], Financial.where(is_estimate: true).distinct.order(:fiscal_year).pluck(:fiscal_year)
    assert_equal [2023, 2024, 2025, 2026], nvg.actual_financials.pluck(:fiscal_year)
  end

  test "market data is priced off the target multiple as of the snapshot date" do
    assert_equal 7, MarketDatum.count
    MarketDatum.includes(:company).find_each do |md|
      spec = Seed::Demo::COMPANIES.find { |c| c[:ticker] == md.company.ticker }
      fin = spec[:fin]
      assert_equal Date.new(2026, 10, 9), md.as_of
      assert_equal REFERENCE_PRICES[md.company.ticker], md.share_price
      assert_equal [fin[:shares], fin[:net_debt], fin[:beta]], [md.shares_diluted, md.net_debt, md.beta]
      assert_nil md.shares_basic # the demo has one share count, as the reference did
      assert_operator md.week52_low, :<, md.share_price
      assert_operator md.week52_high, :>, md.share_price
      implied = (md.share_price * md.shares_diluted + md.net_debt) / (fin[:revenue] * fin[:ebitda_margin])
      assert_in_delta fin[:ev_ebitda_target], implied, 0.01, md.company.ticker
    end
  end

  test "precedent transactions" do
    assert_equal Seed::Demo::TRANSACTIONS.map { |t| t[:target] }.sort, Transaction.pluck(:target).sort
    deal = Transaction.find_by!(target: "Arclight Grid Software")
    assert_equal Date.new(2026, 6, 18), deal.announced_on
    assert_equal [4100.0, 6.4, 22.8, 0.31, "Cash", Seed::Demo::SECTOR],
                 [deal.ev, deal.ev_revenue, deal.ev_ebitda, deal.premium_1day, deal.consideration, deal.sector]
    assert_equal "Arclight Grid Software", Transaction.newest_first.first.target
  end

  test "narrative arc: late periods carry the late themes" do
    transcripts = Document.where(doc_type: "transcript")
    late = transcripts.where(published_at: Date.new(2026, 1, 1)..)
    early = transcripts.where(published_at: ...Date.new(2026, 1, 1))
    assert_equal [21, 35], [late.count, early.count]
    late.find_each { |d| assert Seed::Demo::LATE_THEMES.any? { |t| d.body.include?(t) }, d.title }
    early.find_each { |d| assert Seed::Demo::EARLY_THEMES.any? { |t| d.body.include?(t) }, d.title }
    early.find_each { |d| assert Seed::Demo::LATE_THEMES.none? { |t| d.body.include?(t) }, d.title }
  end

  test "research notes follow the call by two days and news within six weeks" do
    Company.find_each do |company|
      calls = company.documents.where(doc_type: "transcript").order(:published_at).pluck(:published_at)
      assert_equal Seed::Demo::PERIODS.map(&:last), calls
      notes = company.documents.where(doc_type: "research").order(:published_at).pluck(:published_at)
      assert_equal [0, 2, 4, 6].map { |i| calls[i] + 2 }, notes
      news = company.documents.where(doc_type: "news").order(:published_at).pluck(:published_at)
      [1, 4, 7].zip(news).each { |i, when_| assert_includes (calls[i] + 6)..(calls[i] + 40), when_ }
      filing = company.documents.find_by!(doc_type: "filing")
      assert_equal [Date.new(2026, 2, 14), "#{company.ticker}-10K-2025"], [filing.published_at, filing.external_id]
    end
    assert_equal [Date.new(2025, 9, 17), Date.new(2026, 3, 5), Date.new(2026, 6, 11), Date.new(2026, 8, 28)],
                 Document.where(doc_type: "expert-call").order(:published_at).pluck(:published_at)
  end

  test "transcripts are chunked by speaker and yield period-tagged KPIs" do
    chunks = Chunk.joins(:document).where(documents: { doc_type: "transcript" })
    assert_equal 0, chunks.where(speaker: nil).count
    assert_equal SeedDemoGeneratorsTest::SPEAKERS.sort, chunks.distinct.pluck(:speaker).sort
    kpis = Kpi.joins(:document).where(documents: { doc_type: "transcript" })
    assert_operator kpis.count, :>, 0
    assert_empty kpis.distinct.pluck(:period) - Seed::Demo::PERIODS.map(&:first)
    assert_includes Kpi.distinct.pluck(:metric), "ebitda_margin"
    assert_equal 0, Kpi.joins(:document).where.not(documents: { company_id: nil }).where(company_id: nil).count
  end

  test "the search index is populated by the ingest triggers" do
    assert_operator fts_match_count("interconnection"), :>, 0
    assert_operator fts_match_count("tariff"), :>, 0
    assert_equal Chunk.count, ActiveRecord::Base.connection.select_value("SELECT COUNT(*) FROM chunks_fts")
  end

  test "sentiment follows the company tone" do
    avg = ->(ticker) { Document.joins(:company).where(companies: { ticker: ticker }).average(:sentiment).to_f }
    assert_operator avg.call("PYLN"), :>, 0.1 # tone 0.70
    assert_operator avg.call("MFCL"), :<, -0.1 # tone -0.45
    assert_operator avg.call("CRGD"), :>, avg.call("TWSW")
  end
end

class SeedDemoIdempotencyTest < ActiveSupport::TestCase
  include SeedDemoTestHelpers

  setup { purge! }

  test "a second seed adds no documents and duplicates nothing" do
    first = Seed::Demo.seed!
    second = Seed::Demo.seed!
    assert_equal 0, second[:documents_added]
    assert_equal 116, second[:documents_skipped]
    assert_equal first.except(:documents_added, :documents_skipped), second.except(:documents_added, :documents_skipped)
    assert_equal [7, 42, 7, 6, 116], [Company.count, Financial.count, MarketDatum.count, Transaction.count, Document.count]
    assert_equal first[:chunks], Chunk.count
    assert_equal first[:kpis], Kpi.count
    assert_equal Chunk.count, ActiveRecord::Base.connection.select_value("SELECT COUNT(*) FROM chunks_fts")
  end

  test "re-seeding refreshes company fundamentals in place" do
    Seed::Demo.seed!
    nvg = Company.find_ticker("NVG")
    nvg.update!(name: "Renamed Co", employees: 1)
    nvg.financials.find_by!(fiscal_year: 2026).update!(revenue: 1.0)
    nvg.market_datum.update!(share_price: 1.0)
    Seed::Demo.seed!
    nvg.reload
    assert_equal ["NovaGrid Systems", 4280], [nvg.name, nvg.employees]
    assert_equal 1840.0, nvg.financials.find_by!(fiscal_year: 2026).revenue
    assert_equal 44.1, nvg.market_datum.reload.share_price
    assert_equal 6, nvg.financials.count
    assert_equal 1, MarketDatum.where(company_id: nvg.id).count
    # Documents already attached to the company keep their link.
    assert_equal 16, nvg.documents.count
  end

  test "precedent transactions are only loaded into an empty table" do
    Seed::Demo.seed!
    Transaction.find_by!(target: "Keystone DERMS").destroy
    assert_equal 5, Seed::Demo.seed!(rng_seed: 1)[:transactions]
    assert_equal 5, Transaction.count

    purge!
    Transaction.create!(announced_on: Date.new(2026, 1, 1), target: "User deal", acquirer: "User")
    assert_equal 1, Seed::Demo.seed![:transactions]
    assert_equal ["User deal"], Transaction.pluck(:target)
  end
end

class SeedDemoDeterminismTest < ActiveSupport::TestCase
  include SeedDemoTestHelpers

  setup { purge! }

  def snapshot
    {
      documents: Document.order(:external_id).pluck(:external_id, :title, :doc_type, :published_at, :body, :sentiment),
      market: MarketDatum.joins(:company).order("companies.ticker").pluck(:share_price, :week52_low, :week52_high),
      kpis: Kpi.joins(:document).order("documents.external_id", :metric, :value).pluck(:metric, :value, :period)
    }
  end

  test "the same seed reproduces the same corpus in a fresh database" do
    Seed::Demo.seed!
    first = snapshot
    purge!
    assert_equal 0, Document.count
    Seed::Demo.seed!
    second = snapshot
    assert_equal first[:documents].map { |d| d[1] }, second[:documents].map { |d| d[1] } # titles
    assert_equal first, second
  end

  test "a different seed changes the random draws but not the shape" do
    Seed::Demo.seed!(rng_seed: 1)
    other = snapshot
    purge!
    summary = Seed::Demo.seed!
    assert_equal 116, summary[:documents_added]
    assert_equal other[:documents].size, Document.count
    assert_equal other[:market].map(&:first), snapshot[:market].map(&:first) # prices are RNG-free
    refute_equal other[:market], snapshot[:market]
    refute_equal other[:documents].map(&:last), snapshot[:documents].map(&:last)
  end
end
