# frozen_string_literal: true

require "test_helper"

# Port of tests/test_pitchbook.py (CreationTests, EditingTests, EvidenceTests,
# CompSuggestionTests) plus the contract's additions: the audit's prose rules
# (items 16–19), the DCF payload (item 18), the comps disclosures (item 17),
# the stamp and staleness warning (item 22), and decks whose target has no net
# debt or no beta. The corpus is seeded once; each test removes the decks it
# creates, and tests that change shared data do it inside a rolled-back
# transaction.
class PitchbooksTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  BANNED = [/\bupside\b/i, /\bmodest\b/i, /% move\b/i, /accretive margin profile/i, /emphasis rather than/i].freeze

  setup do
    Seed::Demo.seed! unless Document.exists?
    @created = []
  end

  teardown do
    @created.each { |book| Pitchbooks.delete!(book) if Pitchbook.exists?(book.id) }
  end

  def build(**opts)
    book = Pitchbooks.create!(title: "Project Test", target_ticker: "NVG", **opts)
    @created << book
    book
  end

  def slide(book, kind)
    book.slides.reload.find { |s| s.kind == kind }
  end

  def payload(book, kind)
    slide(book, kind).payload_hash
  end

  # Every sentence a reader sees in the deck's prose fields.
  def prose(book)
    book.slides.reload.flat_map do |s|
      p = s.payload_hash
      [s.title, s.subtitle, p[:narrative], p[:note], p[:dcf_note], p[:share_count_basis], *Array(p[:notes])] +
        Array(p[:bullets]).map { |b| b.is_a?(Hash) ? b[:text] : b } +
        Array(p[:candidates]).map { |c| c[:rationale] }
    end.compact.map(&:to_s)
  end

  # Run a block against modified data and undo every write afterwards.
  def with_rollback
    ActiveRecord::Base.transaction do
      yield
      raise ActiveRecord::Rollback
    end
  end

  # ------------------------------------------------------------ creation

  test "every standard slide is generated in order" do
    book = build(client_name: "Board of NovaGrid Systems", banker: "Argos Advisory")
    assert_equal Pitchbooks::SLIDE_ORDER.map(&:first), book.slides.map(&:kind)
    assert_equal (0...14).to_a, book.slides.map(&:seq)
    assert_equal 14, Pitchbooks::SLIDE_ORDER.size
  end

  test "comps are suggested when not supplied" do
    comps = Pitchbooks.comp_tickers_for(build)
    assert comps.any?
    assert_not_includes comps, "NVG"
  end

  test "unknown target is rejected" do
    assert_raises(ArgumentError) { Pitchbooks.create!(title: "X", target_ticker: "NOPE") }
    assert_not Pitchbook.exists?(title: "X")
  end

  test "executive summary cites the corpus" do
    cited = payload(build, "executive_summary")[:bullets].select { |b| b[:source] }
    assert cited.any?, "executive summary should quote the research corpus"
    assert(cited.all? { |b| b[:source][:document_id] })
  end

  test "valuation slide matches the valuation engine" do
    book = build
    p = payload(book, "valuation_summary")
    field = Valuation.football_field("NVG", book.comp_tickers, assumptions: book.assumptions_hash)
    assert p[:ranges].any?
    assert_operator p[:reference_price], :>, 0
    assert_operator p[:concluded_range][:low], :<, p[:concluded_range][:high]
    assert_equal field[:concluded_range][:low], p[:concluded_range][:low]
    assert_equal field[:concluded_range][:methods], p[:methods]
    assert(p[:ranges].all? { |r| r.key?(:in_conclusion) && r.key?(:reference) && r.key?(:note) })
    week52 = p[:ranges].find { |r| r[:method].start_with?("52-week") }
    assert week52[:reference]
    assert_not week52[:in_conclusion]
    assert_not_includes p[:methods], week52[:method]
  end

  test "trading comps slide flags the target row and names every basis" do
    p = payload(build, "trading_comps")
    assert p[:target][:is_target]
    assert_not_includes p[:rows].map { |r| r[:ticker] }, "NVG"
    assert(p[:rows].all? { |r| r[:basis].present? })
    assert_equal "FY2026", p[:target][:basis]
    assert p[:price_date].present?
    assert_match(/shares_diluted/, p[:share_count_basis])
    assert_includes p[:footnote], "GAAP operating income plus D&A, unadjusted"
    assert p[:has_ntm]
    assert_not_nil p[:target][:ev_ebitda_ntm]
    assert(p[:rows].all? { |r| r.key?(:ev_ebitda_ntm) })
  end

  test "dcf slide carries projections, assumptions and the audit's disclosures" do
    p = payload(build, "dcf")
    assert p[:projections].any?
    assert p[:assumptions].key?(:wacc)
    assert_in_delta p[:enterprise_value], p[:pv_explicit] + p[:pv_terminal], 0.5
    assert(p[:projections].all? { |row| row.key?(:dep_amort) && row.key?(:nwc_change) })
    assert_equal p[:projections].last[:year] + 1, p[:terminal_year][:year]
    assert p[:terminal_year].key?(:dep_amort)
    assert p[:terminal_year].key?(:nwc_change)
    assert_equal false, p[:wacc_build][:beta_assumed]
    assert p[:wacc_build][:notes].any?
    assert_not_nil p[:stub_fraction]
    assert p[:valuation_date].present?
    assert_not_nil p[:implied_exit_multiple]
    assert_not_nil p[:implied_terminal_growth]
    assert_match(/Cross-check/, p[:notes].join(" "))
  end

  test "market overview uses trending themes with a data-driven narrative" do
    p = payload(build, "market_overview")
    assert p[:themes].any?
    assert p[:narrative].present?
    assert_no_match(/emphasis rather than/, p[:narrative])
    assert(p[:themes].none? { |t| Analytics.boilerplate_theme?(t[:theme]) })
    shift = p[:shift]
    if shift[:toward]
      assert_match(/shifted toward #{Regexp.escape(shift[:toward][:theme])}/, p[:narrative])
      assert_operator shift[:toward][:change], :>=, Pitchbooks::Slides::MarketOverview::SHIFT_POINTS
    else
      assert_match(/topic mix is stable|no shift/, p[:narrative])
    end
  end

  test "market narrative says stable when no theme share moved" do
    trending = { recent_documents: 10, baseline_documents: 10, window_days: 180,
                 themes: [{ theme: "grid storage", mentions: 5, prior_mentions: 5, lift: 1.0 }] }
    text = Pitchbooks::Slides::MarketOverview.narrative(trending, trending[:themes])
    assert_match(/the topic mix is stable/, text)
    assert_no_match(/shifted/, text)
    trending[:themes] << { theme: "tariff costs", mentions: 1, prior_mentions: 6, lift: 0.2 }
    trending[:themes][0] = { theme: "grid storage", mentions: 8, prior_mentions: 2, lift: 4.0 }
    text = Pitchbooks::Slides::MarketOverview.narrative(trending, trending[:themes])
    assert_match(/shifted toward grid storage \(80% of recent documents against 20% before\) from tariff costs/, text)
  end

  test "buyers slide ranks counterparties on their actual figures" do
    candidates = payload(build, "buyers")[:candidates]
    assert candidates.any?
    assert(candidates.any? { |row| row[:type] == "Sponsor" })
    assert(candidates.all? { |row| row[:rationale].present? })
    strategic = candidates.reject { |row| row[:type] == "Sponsor" }
    strategic.each do |row|
      assert_match(/EBITDA margin of \d+\.\d% against the target's \d+\.\d%/, row[:rationale])
      assert_match(/trades at \d+\.\dx .*EV\/EBITDA against the target's \d+\.\dx/, row[:rationale])
      assert_no_match(/accretive/, row[:rationale])
    end
    # No seeded peer is twice NovaGrid's size, so none is credited with capacity.
    assert(strategic.none? { |row| row[:rationale].include?("balance-sheet capacity") })
  end

  test "balance-sheet capacity needs twice the target's EV and leverage under 3x" do
    book = build
    target_ev = book.slides.find { |s| s.kind == "buyers" }.payload_hash[:target_enterprise_value]
    ctx = Pitchbooks::Slides::Context.new(
      metrics: Valuation.company_metrics("NVG"), field: { comps: { rows: [] } }, profile: {}
    )
    big = { name: "Big", ticker: "BIG", enterprise_value: target_ev * 2.5, net_debt: 100.0, ebitda: 1000.0,
            ebitda_margin: 0.3, ev_ebitda: 12.0, basis: "FY2026" }
    levered = big.merge(net_debt: 4000.0)
    assert_includes Pitchbooks::Slides::Buyers.rationale(big, 2.5, ctx), "balance-sheet capacity"
    rationale = Pitchbooks::Slides::Buyers.rationale(levered, 2.5, ctx)
    assert_not_includes rationale, "balance-sheet capacity"
    assert_includes rationale, "4.0x limits debt funding"
  end

  test "the cover carries the build stamp" do
    stamp = payload(build, "cover")[:stamp]
    assert stamp.present?
    assert_match(/\A(\h{4,}|unknown)\z/, stamp[:code_version])
    assert_equal Document.where(company_id: Company.find_ticker("NVG").id).maximum(:published_at).iso8601, stamp[:data_as_of]
    assert_equal Company.find_ticker("NVG").market_datum.as_of.iso8601, stamp[:price_date]
    assert stamp[:built_at].present?
    assert_equal Pitchbooks.code_version, stamp[:code_version]
  end

  test "no slide calls a gap upside or a move, or calls leverage modest" do
    text = prose(build).join("\n")
    BANNED.each { |pattern| assert_no_match(pattern, text) }
    json = build.slides.map(&:payload).join("\n")
    assert_no_match(/\bupside\b/i, json)
    assert_no_match(/\bmodest\b/i, json)
    assert_no_match(/subscription pricing/i, json)
  end

  test "no sentence contains n/a" do
    prose(build).each { |sentence| assert_not Pitchbooks::Slides::Format.na_inside?(sentence), sentence }
  end

  test "every multiple in the executive summary names its period" do
    bullets = payload(build, "executive_summary")[:bullets].map { |b| b[:text] }
    trading = bullets.first
    assert_match(/17\.5x FY2026 EBITDA/, trading)
    assert_match(/\d+\.\dx NTM EBITDA/, trading)
    assert_match(/Implied value at peer multiples and DCF of \$\d+\.\d\d–\$\d+\.\d\d per share/, bullets[1])
    assert_match(/on \d+\.\dx FY2026 EV\/Revenue/, bullets[2])
  end

  test "an NTM EBITDA derived from revenue says so, and no NTM means no NTM clause" do
    metrics = Valuation.company_metrics("NVG").deep_dup
    metrics[:ntm][:ebitda_derived] = true
    ctx = Pitchbooks::Slides::Context.new(metrics: metrics, field: { comps: { rows: [] } }, profile: {})
    assert_match(/\d+\.\dx NTM EBITDA \(derived at current margin\)\.\z/, Pitchbooks::Slides::ExecutiveSummary.trading_sentence(ctx))
    metrics[:ntm] = nil
    sentence = Pitchbooks::Slides::ExecutiveSummary.trading_sentence(ctx)
    assert_no_match(/NTM/, sentence)
    assert_match(/or 17\.5x FY2026 EBITDA\.\z/, sentence)
  end

  test "the lowest-margin target sits below the peer median, with both numbers" do
    margins = Company.all.to_h { |c| [c.ticker, Valuation.company_metrics(c.ticker)&.dig(:valuation_basis, :ebitda_margin)] }.compact
    lowest = margins.min_by { |_, m| m }.first
    book = Pitchbooks.create!(title: "Project Low", target_ticker: lowest)
    @created << book
    p = payload(book, "executive_summary")
    sentence = p[:bullets].map { |b| b[:text] }.find { |t| t.include?("peer median") }
    target = Pitchbooks::Slides::Format.pct(margins[lowest])
    median = Pitchbooks::Slides::Format.pct(p[:peer_median_margin])
    assert_includes sentence, "#{target} EBITDA margin"
    assert_includes sentence, "below the peer median of #{median}"
    assert_operator p[:peer_median_margin], :>, margins[lowest] + 0.02
  end

  test "process and counterparties phrase leverage from the net debt / EBITDA band" do
    book = build
    leverage = payload(book, "process")[:bullets].find { |b| b.start_with?("Net debt") }
    # NovaGrid: 410 / 482.1 = 0.85x.
    assert_equal "Net debt of $410m is 0.9x FY2026 EBITDA of $482m (below 1x), leaving room for a leveraged structure.", leverage
    sponsor = payload(book, "buyers")[:candidates].find { |c| c[:type] == "Sponsor" }
    assert_includes sponsor[:rationale], "0.9x FY2026 EBITDA"
    diligence = payload(book, "process")[:bullets].find { |b| b.start_with?("Diligence focus") }
    assert_no_match(/subscription/, diligence)

    assert_equal "net cash of $60m against FY2026 EBITDA of $96m", Pitchbooks::Slides::Format.leverage(-60.0, 95.7, "FY2026")
    assert_match(/2\.0x .*\(between 1x and 3x\)/, Pitchbooks::Slides::Format.leverage(200.0, 100.0, "FY2026"))
    assert_match(/4\.0x .*\(above 3x\)/, Pitchbooks::Slides::Format.leverage(400.0, 100.0, "LTM Jun-26"))
    assert_nil Pitchbooks::Slides::Format.leverage(nil, 100.0, "FY2026")
  end

  test "a target with unknown net debt builds without n/a in a sentence" do
    with_rollback do
      Company.find_ticker("NVG").market_datum.update_columns(net_debt: nil)
      book = Pitchbooks.create!(title: "Project Unknown Debt", target_ticker: "NVG")
      sentences = prose(book)
      sentences.each { |s| assert_not Pitchbooks::Slides::Format.na_inside?(s), s }
      summary = payload(book, "executive_summary")[:bullets].map { |b| b[:text] }
      assert(summary.any? { |t| t.include?("net debt is not loaded") })
      assert_nil payload(book, "valuation_summary")[:concluded_range][:low]
      assert(summary.any? { |t| t.include?("could not be bridged") })
      assert_nil payload(book, "dcf")[:value_per_share]
      assert_match(/Net debt unknown/, payload(book, "dcf")[:note])
      assert(payload(book, "process")[:bullets].any? { |b| b.include?("Net debt is not loaded") })
      assert(payload(book, "valuation_summary")[:ranges].none? { |r| r[:method] == "DCF" })

      html = Exporters::Html.render_body(book)
      assert_equal 14, html.scan('<section class="slide').size
      html.scan(%r{<li>(.*?)</li>}m).flatten.each { |li| assert_not Pitchbooks::Slides::Format.na_inside?(li), li }
      html.scan(%r{<p class="note">(.*?)</p>}m).flatten.each { |note| assert_not Pitchbooks::Slides::Format.na_inside?(note), note }
      raise ActiveRecord::Rollback
    end
  end

  test "the DCF slide says when beta was assumed" do
    with_rollback do
      Company.find_ticker("NVG").market_datum.update_columns(beta: nil)
      book = Pitchbooks.create!(title: "Project No Beta", target_ticker: "NVG")
      p = payload(book, "dcf")
      assert p[:beta_assumed]
      assert_match(/Beta was not loaded/, p[:notes].join(" "))
      assert_includes Exporters::Html.render_body(book), "assumed — not loaded"
      raise ActiveRecord::Rollback
    end
  end

  # --------------------------------------------------------------- staleness

  test "staleness is empty for a fresh deck and reports newer data" do
    book = build
    assert_equal [], Pitchbooks.staleness(book)
    with_rollback do
      Document.order(:id).first.update_columns(created_at: 1.hour.from_now)
      market = Company.find_ticker("NVG").market_datum
      market.update_columns(as_of: market.as_of + 3)
      warnings = Pitchbooks.staleness(book.reload)
      assert_equal 2, warnings.size, warnings.inspect
      assert_match(/1 document was added/, warnings.first)
      assert_match(/Market data is dated/, warnings.last)
    end
  end

  # ---------------------------------------------------------------- editing

  test "editing a slide pins it" do
    book = build
    updated = Pitchbooks.update_slide!(book.slides[2], title: "Our view")
    assert_equal "Our view", updated.title
    assert updated.is_pinned
  end

  test "pinned slides survive a rebuild" do
    book = build
    Pitchbooks.update_slide!(slide(book, "executive_summary"), title: "Hand-written summary")
    Pitchbooks.rebuild_slides!(book)
    assert_equal "Hand-written summary", slide(book, "executive_summary").title
    assert_equal Pitchbooks::SLIDE_ORDER.map(&:first), book.slides.reload.map(&:kind)
  end

  test "a pinned cover keeps its wording and gets a fresh stamp" do
    book = build
    cover = slide(book, "cover")
    Pitchbooks.update_slide!(cover, title: "Hand-written cover")
    cover.update_columns(payload: JSON.generate(cover.payload_hash.merge(stamp: { built_at: "2020-01-01T00:00:00Z" })))
    Pitchbooks.rebuild_slides!(book)
    rebuilt = slide(book, "cover")
    assert_equal "Hand-written cover", rebuilt.title
    assert_not_equal "2020-01-01T00:00:00Z", rebuilt.payload_hash[:stamp][:built_at]
  end

  test "unpinned slides are regenerated" do
    book = build
    Pitchbooks.update_slide!(slide(book, "process"), title: "Temporary", pin: false)
    Pitchbooks.rebuild_slides!(book)
    assert_not_equal "Temporary", slide(book, "process").title
  end

  test "missing slide returns nil" do
    assert_nil Pitchbooks.update_slide!(10**7, title: "x")
  end

  test "reorder" do
    book = build
    reversed = book.slides.map(&:id).reverse
    reordered = Pitchbooks.reorder_slides!(book, reversed)
    assert_equal reversed, reordered.map(&:id)
  end

  test "move a slide up and down" do
    book = build
    ids = book.slides.map(&:id)
    Pitchbooks.move_slide!(book, ids[3], "up")
    assert_equal ids[3], book.slides.reload[2].id
    Pitchbooks.move_slide!(book, ids[3], "down")
    assert_equal ids, book.slides.reload.map(&:id)
    Pitchbooks.move_slide!(book, ids[0], "up") # already first: unchanged
    assert_equal ids, book.slides.reload.map(&:id)
  end

  test "changing comps rebuilds the valuation" do
    book = build
    before = payload(book, "trading_comps")
    assert_equal %w[MFCL TWSW], Pitchbooks.set_comps!(book, %w[TWSW MFCL NVG])
    after = payload(book, "trading_comps")
    assert_equal %w[MFCL TWSW].to_set, after[:rows].map { |r| r[:ticker] }.to_set
    assert_not_equal before[:stats], after[:stats]
  end

  test "assumptions are merged and applied" do
    book = build
    merged = Pitchbooks.set_assumptions!(book, { "wacc" => "0.14", "years" => "" })
    assert_in_delta 0.14, merged[:wacc]
    assert_not merged.key?(:years)
    p = payload(book, "dcf")
    assert_in_delta 0.14, p[:assumptions][:wacc]
    assert_match(/overrides the built-up/, p[:notes].join(" "))
    merged = Pitchbooks.set_assumptions!(book, { terminal_growth: 0.02 })
    assert_in_delta 0.14, merged[:wacc]
    assert_in_delta 0.02, merged[:terminal_growth]
  end

  test "assumptions that break the DCF are rejected and not stored" do
    book = build
    assert_raises(ArgumentError) { Pitchbooks.set_assumptions!(book, { terminal_growth: 0.2 }) }
    assert_equal({}, book.reload.assumptions_hash)
    assert_raises(ArgumentError) { Pitchbooks.set_assumptions!(book, { wacc: "abc" }) }
    assert_equal 14, book.slides.reload.size
  end

  test "delete" do
    book = build
    id = book.id
    assert Pitchbooks.delete!(book)
    assert_not Pitchbook.exists?(id)
    assert_equal 0, Slide.where(pitchbook_id: id).count
    assert_equal 0, CompMember.where(pitchbook_id: id).count
  end

  test "summary and detail rows" do
    book = build
    row = Pitchbooks.summary(book)
    assert_equal "NVG", row[:ticker]
    assert_equal 14, row[:slide_count]
    assert_equal 0, row[:evidence_count]
    assert_includes Pitchbooks.list.map { |r| r[:id] }, book.id
    detail = Pitchbooks.detail(book)
    assert_equal 14, detail[:slides].size
    assert_equal book.comp_tickers, detail[:comps]
    assert_equal({}, detail[:assumptions])
  end

  # --------------------------------------------------------------- evidence

  def chunk
    @chunk ||= Chunk.where("length(text) > 120").order(:id).first
  end

  test "pinning updates the appendix" do
    book = build
    Pitchbooks.add_evidence!(book, quote: chunk.text, document_id: chunk.document_id, chunk_id: chunk.id, note: "Diligence item")
    items = payload(book, "evidence_appendix")[:items]
    assert_equal 1, items.size
    assert_equal chunk.document_id, items.first[:document_id]
    assert_equal "Diligence item", items.first[:note]
    assert_equal "1 pinned item(s) from the research corpus", slide(book, "evidence_appendix").subtitle
  end

  test "quote is recovered from the chunk" do
    evidence = Pitchbooks.add_evidence!(build, quote: "", chunk_id: chunk.id)
    assert evidence.quote.present?
    assert_equal chunk.document_id, evidence.document_id
  end

  test "empty evidence is rejected" do
    assert_raises(ArgumentError) { Pitchbooks.add_evidence!(build, quote: "   ") }
    assert_raises(ArgumentError) { Pitchbooks.add_evidence!(build, quote: "x", document_id: 10**7) }
  end

  test "delete evidence updates the appendix" do
    book = build
    evidence = Pitchbooks.add_evidence!(book, quote: "Churn ticked up.", document_id: chunk.document_id)
    assert Pitchbooks.delete_evidence!(evidence)
    assert_equal [], payload(book, "evidence_appendix")[:items]
    assert_not Pitchbooks.delete_evidence!(evidence.id)
  end

  test "evidence is removed with the deck" do
    book = build
    Pitchbooks.add_evidence!(book, quote: "Churn ticked up.", document_id: chunk.document_id)
    Pitchbooks.delete!(book)
    assert_equal 0, Evidence.where(pitchbook_id: book.id).count
  end

  # ---------------------------------------------------------------- comps

  test "suggestions are same sector and size ranked" do
    comps = Pitchbooks.suggest_comps("PYLN", limit: 3)
    assert comps.any?
    assert_not_includes comps, "PYLN"
    assert_operator comps.size, :<=, 3
    sector = Company.find_ticker("PYLN").sector
    assert(comps.all? { |t| Company.find_ticker(t).sector == sector })
    # Pylon is the smallest seeded company; its nearest peer by revenue is Cerulean.
    assert_equal "CRGD", comps.first
  end
end
