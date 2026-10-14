# frozen_string_literal: true

require "test_helper"

# Port of tests/test_nlp.py, plus coverage for the parts of the contract the
# Python suite exercised only indirectly (tokenizer, corpus, vectors, row shapes).

class NlpSentimentTest < ActiveSupport::TestCase
  test "direction" do
    positive = Nlp.score_sentiment("Revenue growth accelerated and margins expanded to a record level.")
    negative = Nlp.score_sentiment("Demand was weaker and guidance was cut on macro headwinds.")
    assert_operator positive, :>, 0.3
    assert_operator negative, :<, -0.3
  end

  test "negation flips polarity" do
    assert_operator Nlp.score_sentiment("Results were not strong."), :<, 0
    assert_operator Nlp.score_sentiment("Results were strong."), :>, 0
  end

  test "intensifier increases magnitude" do
    plain = Nlp.score_sentiment("Bookings were weak.")
    intense = Nlp.score_sentiment("Bookings were significantly weak.")
    assert_operator intense, :<, plain
  end

  test "empty text is neutral" do
    assert_equal 0.0, Nlp.score_sentiment("")
    assert_equal 0.0, Nlp.score_sentiment(nil)
    assert_equal "neutral", Nlp.sentiment_label(0.0)
  end

  test "labels" do
    assert_equal "positive", Nlp.sentiment_label(0.5)
    assert_equal "negative", Nlp.sentiment_label(-0.5)
    assert_equal "neutral", Nlp.sentiment_label(0.05)
  end

  test "label thresholds are inclusive at plus or minus 0.18" do
    assert_equal "positive", Nlp.sentiment_label(0.18)
    assert_equal "negative", Nlp.sentiment_label(-0.18)
    assert_equal "neutral", Nlp.sentiment_label(0.1799)
  end

  test "scores match the reference implementation" do
    assert_in_delta 0.8518518518518517, Nlp.score_sentiment("Revenue growth accelerated and margins expanded to a record level."), 1e-9
    assert_in_delta(-0.49190985824841454, Nlp.score_sentiment("Demand was weaker and guidance was cut on macro headwinds."), 1e-9)
    assert_in_delta(-0.37777777777777777, Nlp.score_sentiment("Results were not strong."), 1e-9)
    assert_in_delta(-0.6666666666666665, Nlp.score_sentiment("Bookings were significantly weak."), 1e-9)
  end

  test "score is clamped to the unit interval" do
    assert_operator Nlp.score_sentiment("strong strong strong record record beat beat"), :<=, 1.0
    assert_operator Nlp.score_sentiment("weak weak miss miss loss loss"), :>=, -1.0
    assert_in_delta 0.9735449735449734, Nlp.score_sentiment("strong strong strong record record beat beat"), 1e-9
  end
end

class NlpTokenTest < ActiveSupport::TestCase
  test "tokenize lowercases and keeps percentages, decimals, hyphens and ampersands" do
    assert_equal ["record", "3", "revenue", "up", "18.4%", "free-cash", "flow", "m&a", "don't", "stop"],
                 Nlp.tokenize("Record Q3: revenue up 18.4%, free-cash flow & M&A; don't stop")
    assert_equal [], Nlp.tokenize(nil)
    assert_equal [], Nlp.tokenize("")
  end

  test "content tokens drop stopwords, filing boilerplate, short and numeric tokens" do
    assert_equal %w[show growth recurring revenue arr],
                 Nlp.content_tokens("The quarterly unaudited statements show 18.4% growth in recurring revenue and ARR")
  end

  test "stopwords include the filing boilerplate" do
    assert Nlp::FILING_BOILERPLATE.subset?(Nlp::STOPWORDS)
    assert_includes Nlp::STOPWORDS, "quarterly"
    assert_includes Nlp::STOPWORDS, "the"
    assert_equal 112, Nlp::FILING_BOILERPLATE.size
    assert_equal 294, Nlp::STOPWORDS.size
    assert Nlp::STOPWORDS.frozen?
  end

  test "sentences split on terminal punctuation followed by a capital, digit, quote or bracket" do
    text = "Revenue grew. e.g. lower case follows. Then \"quoted\" start! (Paren) start? 9 digits. Ok"
    assert_equal ["Revenue grew. e.g. lower case follows.", "Then \"quoted\" start!", "(Paren) start?", "9 digits."],
                 Nlp.sentences(text)
    assert_equal [], Nlp.sentences("")
    assert_equal [], Nlp.sentences(nil)
  end

  test "sentences treat non-breaking space as whitespace like Python" do
    assert_equal ["One.", "Two."], Nlp.sentences("One. Two.")
  end

  test "lexicons are frozen string-keyed hashes" do
    assert Nlp::POSITIVE_LEXICON.frozen?
    assert Nlp::NEGATIVE_LEXICON.frozen?
    assert_equal 1.2, Nlp::POSITIVE_LEXICON["strong"]
    assert_equal 1.6, Nlp::NEGATIVE_LEXICON["guidance-cut"]
  end
end

class NlpKpiTest < ActiveSupport::TestCase
  test "extracts percentages and currency" do
    text = "Revenue grew 18.4% while gross margin reached 71.2%. " \
           "ARR was $1.4 billion. Net dollar retention of 114%."
    found = Nlp.extract_kpis(text).to_h { |kpi| [kpi[:metric], kpi] }
    assert_in_delta 18.4, found["revenue_growth"][:value], 1e-7
    assert_in_delta 71.2, found["gross_margin"][:value], 1e-7
    assert_in_delta 114.0, found["net_retention"][:value], 1e-7
    # Billions are normalised to millions so the series is comparable.
    assert_in_delta 1400.0, found["arr"][:value], 1e-7
    assert_equal "USDm", found["arr"][:unit]
  end

  test "keeps sentence context" do
    kpis = Nlp.extract_kpis("Headline. Gross margin was 61.0% in the quarter.")
    assert_includes kpis[0][:context], "61.0%"
  end

  test "no false positives on plain text" do
    assert_equal [], Nlp.extract_kpis("We hired a new chief financial officer.")
    assert_equal [], Nlp.extract_kpis("")
  end

  test "every pattern, unit and the bn/m suffixes behave like the reference" do
    text = "Headcount rose to 1,250 employees. ARR of $500m. Backlog was $2.1bn. Free cash flow of $75 million. " \
           "Capex was 6.5% of revenue. Revenue declined 3% year over year. Churn of 2.1%. " \
           "Adjusted EBITDA margin expanded to 31.5%. Operating margin was 12%."
    expected = [
      { metric: "headcount", value: 1250.0, unit: "count", context: "Headcount rose to 1,250 employees." },
      { metric: "arr", value: 500.0, unit: "USDm", context: "ARR of $500m." },
      { metric: "backlog", value: 2100.0, unit: "USDm", context: "Backlog was $2.1bn." },
      { metric: "free_cash_flow", value: 75.0, unit: "USDm", context: "Free cash flow of $75 million." },
      { metric: "capex_intensity", value: 6.5, unit: "%", context: "Capex was 6.5% of revenue." },
      { metric: "revenue_decline", value: 3.0, unit: "%", context: "Revenue declined 3% year over year." },
      { metric: "churn", value: 2.1, unit: "%", context: "Churn of 2.1%." },
      { metric: "ebitda_margin", value: 31.5, unit: "%", context: "Adjusted EBITDA margin expanded to 31.5%." },
      { metric: "operating_margin", value: 12.0, unit: "%", context: "Operating margin was 12%." }
    ]
    assert_equal expected, Nlp.extract_kpis(text)
    Nlp.extract_kpis(text).each { |kpi| assert_kind_of Float, kpi[:value] }
  end

  test "text without sentence breaks is scanned whole" do
    kpis = Nlp.extract_kpis("gross margin of 40%")
    assert_equal [{ metric: "gross_margin", value: 40.0, unit: "%", context: "gross margin of 40%" }], kpis
  end
end

class NlpSummaryTest < ActiveSupport::TestCase
  test "returns sentences in source order" do
    text = "Revenue grew 18%. We see headwinds in EMEA. " \
           "Margins expanded 240bps on pricing discipline. The CFO will retire."
    summary = Nlp.summarize(text, limit: 2)
    assert_equal 2, summary.size
    assert_equal summary.sort_by { |s| text.index(s) }, summary
    assert_equal ["Revenue grew 18%.", "Margins expanded 240bps on pricing discipline."], summary
  end

  test "short text returned whole" do
    assert_equal ["One sentence only."], Nlp.summarize("One sentence only.", limit: 4)
    assert_equal [], Nlp.summarize("")
  end

  test "query terms bias selection" do
    text = "The weather was fine. Churn improved materially this quarter. " \
           "We opened a new office. Headcount was flat. Travel costs fell."
    summary = Nlp.summarize(text, limit: 1, query_terms: ["churn"])
    assert_includes summary[0], "Churn"
  end
end

class NlpThemeTest < ActiveSupport::TestCase
  test "lift favours newly emerging phrases" do
    recent = ["interconnection queue backlog is the constraint"] * 3
    baseline = ["storm hardening programmes dominate the plan"] * 3
    themes = Nlp.theme_trends(recent, baseline, limit: 10).map { |row| row[:theme] }.to_set
    assert themes.any? { |theme| theme.include?("interconnection") }
    assert_not themes.any? { |theme| theme.include?("storm") }
  end

  test "contained themes are removed" do
    recent = ["datacenter load growth"] * 4
    themes = Nlp.theme_trends(recent, ["unrelated text here"] * 4, limit: 10).map { |row| row[:theme] }
    # "load" must not take a slot next to "datacenter load".
    assert_not_includes themes, "load"
  end

  test "rows carry the contract keys and the reference lift and rank" do
    rows = Nlp.theme_trends(["datacenter load growth"] * 4, ["unrelated text here"] * 4, limit: 10)
    assert_equal [
      { theme: "datacenter load", mentions: 4, prior_mentions: 0, lift: 5.0, rank: 9.716 },
      { theme: "load growth", mentions: 4, prior_mentions: 0, lift: 5.0, rank: 9.716 }
    ], rows
    assert_equal %i[theme mentions prior_mentions lift rank], rows.first.keys
  end

  test "lift is the ratio of normalised document frequencies" do
    recent = ["grid software demand rose sharply"] * 4
    baseline = ["grid software demand rose sharply"] * 2 + ["other text entirely here"] * 6
    rows = Nlp.theme_trends(recent, baseline, limit: 5)
    assert_equal 4, rows.size
    rows.each do |row|
      assert_equal 2, row[:prior_mentions]
      assert_equal 4.0, row[:lift] # (4/4) / (2/8)
      assert_equal 7.773, row[:rank] # 4 * 1.25 * (1 + 0.4 ln 4)
    end
    assert_equal ["demand rose", "grid software", "rose sharply", "software demand"], rows.map { |r| r[:theme] }
  end

  test "min_recent floor suppresses single-document themes" do
    assert_equal [], Nlp.theme_trends(["datacenter load growth"], ["x"])
    rows = Nlp.theme_trends(["datacenter load growth"], ["x"], min_recent: 1)
    assert_equal ["datacenter load", "load growth"], rows.map { |r| r[:theme] }
    assert_equal [1, 2.0, 2.5], rows.first.values_at(:mentions, :lift, :rank)
  end

  test "empty inputs and lazy enumerables are accepted" do
    assert_equal [], Nlp.theme_trends([], [])
    rows = Nlp.theme_trends((["datacenter load growth"] * 4).each, [].each, limit: 1)
    assert_equal 1, rows.size
  end

  test "expand query terms is ordered and unique" do
    expanded = Nlp.expand_query_terms(%w[guidance guidance])
    assert_equal "guidance", expanded[0]
    assert_equal expanded.uniq.size, expanded.size
    assert_includes expanded, "outlook"
  end

  test "expand query terms lowercases and passes unknown terms through" do
    assert_equal ["m&a", "acquisition", "merger", "takeover", "guidance", "outlook", "forecast", "guide", "zebra"],
                 Nlp.expand_query_terms(["M&A", "Guidance", "zebra", "guidance"])
  end
end

class NlpHeadingTest < ActiveSupport::TestCase
  test "title case headings are detected" do
    assert Nlp.looks_like_heading("Item 2. Unregistered Sales of Equity Securities and Use of Proceeds")
    assert Nlp.looks_like_heading("Management's Discussion and Analysis of Financial Condition and Results of Operations")
    assert_not Nlp.looks_like_heading("Total backlog at quarter end was $4.4 billion compared with $4.5 billion.")
    assert_not Nlp.looks_like_heading("Backlog")
  end

  test "fused heading prefix is stripped" do
    fused = "Unregistered Sales of Equity Securities and Use of Proceeds none were sold this quarter."
    assert_equal "none were sold this quarter.", Nlp.strip_leading_heading(fused)
    # Connectors trailing the heading go with it.
    assert_equal "our products fell.", Nlp.strip_leading_heading("Risk Factors Sales of our products fell.")
    assert_equal "Revenue grew because demand was strong.", Nlp.strip_leading_heading("Revenue grew because demand was strong.")
    assert_equal "", Nlp.strip_leading_heading("Liquidity and Capital Resources")
    # Two-word headings are left for looks_like_heading to catch whole.
    assert_equal "Results of Operations", Nlp.strip_leading_heading("Results of Operations")
  end

  test "item numbers and bracketed words count towards the heading run" do
    assert_equal "none sold.", Nlp.strip_leading_heading("Item 2. Unregistered Sales of Equity Securities none sold.")
    assert_equal "revenue fell.", Nlp.strip_leading_heading("(Unaudited) Condensed Consolidated Statements revenue fell.")
  end

  test "headings do not become themes" do
    recent = ["Item 2. Unregistered Sales of Equity Securities and Use of Proceeds. " \
              "Demand for grid software rose across the utility base this quarter."] * 4
    themes = Nlp.theme_trends(recent, ["Quiet baseline text about nothing."] * 4, limit: 20).map { |row| row[:theme] }
    assert_not_includes themes, "equity use"
    assert_not_includes themes, "sales equity"
  end
end

class NlpTableRowTest < ActiveSupport::TestCase
  test "detects flattened table rows" do
    assert Nlp.looks_like_table_row("374.1 $ 325.9 Gross margin 49.0 % 50.6 % 540 bps")
    assert_not Nlp.looks_like_table_row("Gross margin expanded to 49.0% on favourable mix.")
  end

  test "fewer than four tokens is never a table row" do
    assert_not Nlp.looks_like_table_row("$ 1 2")
    assert Nlp.looks_like_table_row("1 2 3 4")
  end

  test "summary skips table rows" do
    text = "Revenue grew 12% on strong demand. 71,344 305,957 63,536 440,837 29.9 % 37.7 % 38.8 %. " \
           "Backlog ended the quarter at $4.4 billion."
    summary = Nlp.summarize(text, limit: 2)
    assert_not summary.any? { |s| Nlp.looks_like_table_row(s) }
    assert_equal ["Revenue grew 12% on strong demand.", "Backlog ended the quarter at $4.4 billion."], summary
  end

  test "themes do not bridge headings" do
    recent = ["Item 1A. Risk Factors. Item 2. Unregistered Sales of Equity Securities. " \
              "Demand for interconnection software grew strongly across the utility customer base this year."] * 4
    baseline = ["Nothing in particular happened during the comparison window at all."] * 4
    themes = Nlp.theme_trends(recent, baseline, limit: 20).map { |row| row[:theme] }
    assert_not_includes themes, "factors sales"
    assert_not_includes themes, "sales equity"
    assert themes.any? { |t| t.include?("interconnection") }
  end

  test "filing boilerplate is not a theme" do
    recent = ["condensed consolidated statements unaudited quarterly period item part"] * 4
    baseline = ["annual report risk factors"] * 4
    themes = Nlp.theme_trends(recent, baseline).map { |row| row[:theme] }
    assert_not %w[quarterly unaudited item].any? { |word| themes.include?(word) }
  end
end

class NlpKeywordTest < ActiveSupport::TestCase
  test "repeated terms outrank singletons" do
    text = (["interconnection queue"] * 5 + %w[sporadic irrelevant oneoff]).join(" ")
    top = Nlp.keywords(text, limit: 3).map { |term, _| term }
    assert top.any? { |term| term.include?("interconnection") }
  end

  test "empty input" do
    assert_equal [], Nlp.keywords("")
    assert_equal [], Nlp.keywords(nil)
  end

  test "returns term and score pairs with bigrams scored 1.45x the mean idf" do
    text = (["interconnection queue"] * 5 + %w[sporadic irrelevant oneoff]).join(" ")
    ranked = Nlp.keywords(text, limit: 3)
    assert_equal ["interconnection queue", "queue interconnection", "interconnection"], ranked.map(&:first)
    assert_in_delta 3.7836849730294455, ranked[0][1], 1e-9
    assert_in_delta 3.4601268236238414, ranked[1][1], 1e-9
    assert_in_delta 2.6094379124341005, ranked[2][1], 1e-9
  end

  test "corpus idf demotes terms common across documents" do
    corpus = Nlp::Corpus.new
    corpus.add("alpha beta gamma")
    corpus.add("alpha delta")
    ranked = Nlp.keywords("alpha alpha beta beta gamma", corpus: corpus, limit: 5)
    assert_equal %w[beta alpha gamma], ranked.map(&:first)
    assert_in_delta 2.3796592851687173, ranked[0][1], 1e-9
    assert_in_delta 1.6931471805599454, ranked[1][1], 1e-9
    assert_in_delta 1.4054651081081644, ranked[2][1], 1e-9
  end
end

class NlpCorpusTest < ActiveSupport::TestCase
  test "tracks document count and per-document frequency" do
    corpus = Nlp::Corpus.new
    corpus.add("alpha beta gamma alpha")
    corpus.add("alpha delta")
    assert_equal 2, corpus.doc_count
    assert_equal({ "alpha" => 2, "beta" => 1, "gamma" => 1, "delta" => 1 }, corpus.doc_freq)
    assert_in_delta 1.0, corpus.idf("alpha"), 1e-12
    assert_in_delta 1.4054651081081644, corpus.idf("beta"), 1e-12
    assert_in_delta 2.09861228866811, corpus.idf("unseen"), 1e-12
  end

  test "can be rebuilt from stored statistics" do
    corpus = Nlp::Corpus.new(doc_count: 2, doc_freq: { "alpha" => 2 })
    assert_equal 2, corpus.doc_count
    assert_in_delta 1.0, corpus.idf("alpha"), 1e-12
    assert_in_delta 2.09861228866811, corpus.idf("missing"), 1e-12
  end
end

class NlpVectorTest < ActiveSupport::TestCase
  test "vector is raw counts without a corpus and idf-weighted with one" do
    corpus = Nlp::Corpus.new
    corpus.add("alpha beta gamma")
    corpus.add("alpha delta")
    assert_equal({ "alpha" => 2, "beta" => 1 }, Nlp.vector("alpha alpha beta"))
    weighted = Nlp.vector("alpha alpha beta", corpus)
    assert_in_delta 2.0, weighted["alpha"], 1e-12
    assert_in_delta 1.4054651081081644, weighted["beta"], 1e-12
  end

  test "cosine similarity" do
    assert_in_delta 1.0, Nlp.cosine_similarity({ "a" => 1, "b" => 2 }, { "a" => 1, "b" => 2 }), 1e-9
    assert_equal 0.0, Nlp.cosine_similarity({ "a" => 1 }, { "b" => 1 })
    assert_in_delta 0.5, Nlp.cosine_similarity({ "a" => 1, "b" => 1 }, { "a" => 1, "c" => 1 }), 1e-9
    assert_equal 0.0, Nlp.cosine_similarity({}, { "a" => 1 })
    assert_equal 0.0, Nlp.cosine_similarity(nil, { "a" => 1 })
  end
end


class NlpKpiBoundsTest < ActiveSupport::TestCase
  test "a year masquerading as a headcount is rejected, a real count is kept" do
    year = Nlp.extract_kpis("Options were granted to employees under the 2004 Stock Incentive Plan.")
    assert_empty year.select { |k| k[:metric] == "headcount" }
    real = Nlp.extract_kpis("Headcount was 2,004 at year end.")
    assert_equal [2004.0], real.select { |k| k[:metric] == "headcount" }.map { |k| k[:value] }
  end

  test "margins above 100 percent are rejected but retention above 100 is kept" do
    assert_empty Nlp.extract_kpis("Adjusted EBITDA margin 120 % was reported in the table.")
    assert_equal [27.7], Nlp.extract_kpis("Adjusted EBITDA margin was 27.7%.").map { |k| k[:value] }
    assert_equal [114.0], Nlp.extract_kpis("Net dollar retention of 114%.").map { |k| k[:value] }
  end

  test "negative currency amounts are rejected" do
    assert_empty Nlp.extract_kpis("Free cash flow -$12 million.").select { |k| k[:metric] == "free_cash_flow" && k[:value].negative? }
  end
end
