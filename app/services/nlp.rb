# frozen_string_literal: true

require "set"

# Lightweight, dependency-free text analytics.
#
# Everything here runs locally: a finance-tuned sentiment lexicon, tf-idf keyword
# and theme extraction, an extractive summarizer and a KPI pattern matcher. No
# network calls and no model downloads, so the app behaves identically offline and
# in CI.
#
# Port of argos/nlp.py. Regex translation notes: Python's str patterns treat
# \d and \s as Unicode (digits of any script, NBSP and friends), Ruby's are
# ASCII-only, so the POSIX classes [[:digit:]] / [[:space:]] are used wherever
# the reference relied on \d, \s, str.split() or str.strip(). The KPI patterns
# keep ASCII \d because Ruby's Float() cannot parse non-ASCII digits anyway.
module Nlp
  WORD_RE = %r{[A-Za-z][A-Za-z'&/-]+|[[:digit:]]+(?:\.[[:digit:]]+)?%?}
  SENTENCE_RE = /(?<=[.!?])[[:space:]]+(?=[A-Z0-9"'(])/
  # Python's str.split() / str.strip() semantics: any Unicode whitespace.
  WS_RE = /[[:space:]]+/
  EDGE_WS_RE = /\A[[:space:]]+|[[:space:]]+\z/

  BASE_STOPWORDS = Set.new(<<~WORDS.split).freeze
    a about above after again against all also am an and any are aren't as at be because been
    before being below between both but by can cannot could couldn't did didn't do does doesn't
    doing don't down during each few for from further had hadn't has hasn't have haven't having
    he her here hers herself him himself his how i if in into is isn't it its itself just let's
    me more most mustn't my myself no nor not of off on once only or other ought our ours
    ourselves out over own same shan't she should shouldn't so some such than that that's the
    their theirs them themselves then there these they this those through to too under until up
    very was wasn't we were weren't what when where which while who whom why with won't would
    wouldn't you your yours yourself yourselves will shall may might must us thing things
    quarter year years thank thanks please question questions next first second third call whether
    going got get go really lot bit kind sort going want want's said say says one two three
  WORDS

  # Structural vocabulary of SEC filings. It is not meaningless, but it is the same
  # in every document, so it can only ever surface as a theme by accident of
  # which filing types happen to fall inside a comparison window.
  FILING_BOILERPLATE = Set.new(<<~WORDS.split).freeze
    act quarterly unaudited item items part statements statement securities proceeds unregistered
    registrant form filed filing incorporated reference exhibit exhibits table contents pursuant
    section herein thereof thereto hereby million millions thousand thousands billion period periods
    ended months month three six nine twelve respectively compared fiscal company inc corporation
    condensed consolidated notes note accompanying december january february march april june july
    august september october november quarter quarters amounts dollars except per share shares
    december31 pages page see refer defined accordance gaap sec commission exchange
    indicate check mark affiliates filer accelerated emerging smaller reporting seasoned shell
    forward-looking contained cause actual results differ materially uncertainties assumptions
    chairman president officer chief executive vice director directors release contact
  WORDS
  STOPWORDS = (BASE_STOPWORDS | FILING_BOILERPLATE).freeze

  # A whole token that is a single figure-ish character ($, %, a bracket, a dash).
  TABLE_ROW_RE = /\A[[:digit:]$%()—–-]\z/
  TABLE_TOKEN_TRIM_RE = /\A[.,;:]+|[.,;:]+\z/

  HEADING_CONNECTORS = Set.new(%w[of and the for to in on a an or & by with]).freeze
  HEADING_WORD_TRIM_RE = /\A[().,;:'"]+|[().,;:'"]+\z/

  # Finance-tuned polarity. Values are deliberately coarse: the signal that matters
  # is direction and relative intensity across a corpus, not a calibrated score.
  POSITIVE_LEXICON = {
    "accelerate" => 1.4, "accelerated" => 1.4, "accelerating" => 1.5, "acceleration" => 1.5,
    "accretive" => 1.2, "advantage" => 0.8, "ahead" => 1.0, "beat" => 1.5, "benefit" => 0.8,
    "best" => 1.0, "boost" => 1.1, "breakthrough" => 1.3, "confident" => 1.2, "confidence" => 1.0,
    "demand" => 0.5, "disciplined" => 0.9, "durable" => 1.0, "efficiency" => 0.8, "efficient" => 0.8,
    "exceed" => 1.5, "exceeded" => 1.5, "exceeding" => 1.5, "expand" => 0.9, "expanded" => 1.0,
    "expanding" => 1.0, "expansion" => 1.0, "favorable" => 1.1, "gain" => 0.9, "gains" => 0.9,
    "grew" => 1.1, "growth" => 0.9, "improve" => 1.0, "improved" => 1.1, "improvement" => 1.1,
    "improving" => 1.1, "increase" => 0.7, "increased" => 0.8, "leadership" => 0.8, "momentum" => 1.3,
    "opportunity" => 0.8, "outperform" => 1.5, "outperformed" => 1.5, "outstanding" => 1.3,
    "premium" => 0.5, "profitable" => 1.2, "profitability" => 1.0, "raise" => 1.2, "raised" => 1.3,
    "raising" => 1.3, "record" => 1.3, "resilient" => 1.1, "robust" => 1.2, "stabilized" => 0.7,
    "strength" => 1.1, "strong" => 1.2, "stronger" => 1.3, "strongest" => 1.4, "surpassed" => 1.5,
    "tailwind" => 1.3, "tailwinds" => 1.3, "upside" => 1.2, "upgrade" => 1.3, "win" => 1.0, "wins" => 1.0
  }.freeze
  NEGATIVE_LEXICON = {
    "adverse" => 1.1, "below" => 0.9, "challenge" => 0.9, "challenged" => 1.1, "challenging" => 1.1,
    "churn" => 1.2, "compression" => 1.2, "concern" => 1.0, "concerns" => 1.0, "contraction" => 1.3,
    "decelerate" => 1.4, "decelerated" => 1.4, "decelerating" => 1.5, "deceleration" => 1.5,
    "decline" => 1.2, "declined" => 1.2, "declining" => 1.3, "deficit" => 1.1, "delay" => 1.1,
    "delayed" => 1.2, "delays" => 1.2, "deteriorate" => 1.4, "deteriorating" => 1.4, "difficult" => 1.0,
    "dilution" => 1.0, "dilutive" => 1.0, "disappointing" => 1.5, "downgrade" => 1.3, "downside" => 1.2,
    "downturn" => 1.4, "guidance-cut" => 1.6, "headwind" => 1.3, "headwinds" => 1.3, "impairment" => 1.3,
    "litigation" => 1.0, "loss" => 1.2, "losses" => 1.2, "miss" => 1.4, "missed" => 1.4, "pressure" => 1.0,
    "pressured" => 1.1, "recession" => 1.3, "restructuring" => 0.9, "risk" => 0.7, "risks" => 0.7,
    "shortfall" => 1.4, "slow" => 0.9, "slowdown" => 1.4, "slower" => 1.1, "slowing" => 1.2,
    "soft" => 1.0, "softer" => 1.1, "softness" => 1.2, "uncertain" => 1.1, "uncertainty" => 1.1,
    "underperform" => 1.4, "weak" => 1.2, "weaker" => 1.3, "weakness" => 1.3, "writedown" => 1.3
  }.freeze
  NEGATORS = Set.new(%w[not no never without less lack nor hardly barely]).freeze
  INTENSIFIERS = {
    "very" => 1.4, "significantly" => 1.5, "materially" => 1.5, "substantially" => 1.5,
    "slightly" => 0.6, "modestly" => 0.7, "somewhat" => 0.7, "extremely" => 1.6
  }.freeze

  # Query expansion: the vocabulary gap between how analysts ask and how filings
  # are written is the single biggest cause of "no results" in research search.
  SYNONYMS = {
    "guidance" => %w[outlook forecast guide],
    "outlook" => %w[guidance forecast],
    "headwind" => %w[pressure challenge drag],
    "tailwind" => %w[benefit support],
    "margin" => %w[profitability margins],
    "churn" => %w[attrition retention],
    "layoff" => ["workforce reduction", "restructuring", "redundancies"],
    "ai" => ["artificial intelligence", "machine learning", "genai"],
    "capex" => ["capital expenditure", "capital spending"],
    "buyback" => ["repurchase", "share repurchase"],
    "m&a" => %w[acquisition merger takeover],
    "pricing" => ["price increase", "price realization", "list price"],
    "supply chain" => %w[logistics suppliers sourcing],
    "demand" => %w[bookings orders pipeline],
    "recession" => ["downturn", "macro weakness"],
    "cloud" => %w[hyperscaler saas subscription],
    "retention" => %w[renewal churn],
    "backlog" => ["rpo", "remaining performance obligations", "order book"]
  }.transform_values(&:freeze).freeze

  # [metric, pattern, unit]. Patterns are ASCII-digit because Float() is. The
  # number group admits a leading "-", "−" or "negative " so a cash outflow or
  # a negative margin keeps its sign (the reference stored "-$12 million" as
  # +12, which an audit of the KPI series caught).
  KPI_PATTERNS = [
    ["revenue_growth", /revenue[[:space:]]+(?:grew|increased|rose|was up|up)[[:space:]]+(?:by[[:space:]]+)?((?:-|−|negative[[:space:]]+)?\d+(?:\.\d+)?)[[:space:]]?%/i, "%"],
    ["revenue_decline", /revenue[[:space:]]+(?:fell|declined|decreased|was down|down)[[:space:]]+(?:by[[:space:]]+)?((?:-|−|negative[[:space:]]+)?\d+(?:\.\d+)?)[[:space:]]?%/i, "%"],
    ["gross_margin", /gross margin\D{0,24}?((?:-|−|negative[[:space:]]+)?\d+(?:\.\d+)?)[[:space:]]?%/i, "%"],
    ["ebitda_margin", /(?:adjusted[[:space:]]+)?ebitda margin\D{0,24}?((?:-|−|negative[[:space:]]+)?\d+(?:\.\d+)?)[[:space:]]?%/i, "%"],
    ["operating_margin", /operating margin\D{0,24}?((?:-|−|negative[[:space:]]+)?\d+(?:\.\d+)?)[[:space:]]?%/i, "%"],
    ["net_retention", /(?:net (?:dollar )?retention|ndr)\D{0,24}?((?:-|−|negative[[:space:]]+)?\d+(?:\.\d+)?)[[:space:]]?%/i, "%"],
    ["churn", /churn\D{0,24}?((?:-|−|negative[[:space:]]+)?\d+(?:\.\d+)?)[[:space:]]?%/i, "%"],
    ["arr", /(?:arr|annual recurring revenue)\D{0,24}?\$?((?:-|−|negative[[:space:]]+)?\d+(?:\.\d+)?)[[:space:]]?(?:million|m|billion|bn|b)\b/i, "currency"],
    ["backlog", /(?:backlog|rpo|remaining performance obligations)\D{0,24}?\$?((?:-|−|negative[[:space:]]+)?\d+(?:\.\d+)?)[[:space:]]?(?:million|m|billion|bn|b)\b/i, "currency"],
    ["headcount", /(?:headcount|employees)\D{0,24}?([\d,]{3,})\b/i, "count"],
    ["free_cash_flow", /free cash flow\D{0,24}?\$?((?:-|−|negative[[:space:]]+)?\d+(?:\.\d+)?)[[:space:]]?(?:million|m|billion|bn|b)\b/i, "currency"],
    ["capex_intensity", /capex\D{0,24}?((?:-|−|negative[[:space:]]+)?\d+(?:\.\d+)?)[[:space:]]?%[[:space:]]+of revenue/i, "%"]
  ].map(&:freeze).freeze
  BILLIONS_RE = /billion|bn\b|\bb\b/i

  # Document-frequency statistics used for tf-idf keywording.
  class Corpus
    attr_reader :doc_count, :doc_freq

    def initialize(doc_count: 0, doc_freq: nil)
      @doc_count = doc_count
      @doc_freq = Hash.new(0)
      doc_freq&.each { |token, count| @doc_freq[token] = count }
    end

    def add(text)
      @doc_count += 1
      Nlp.content_tokens(text).uniq.each { |token| @doc_freq[token] += 1 }
    end

    def idf(token)
      Math.log((1 + doc_count).fdiv(1 + doc_freq.fetch(token, 0))) + 1.0
    end
  end

  module_function

  # True when a "sentence" is really a row of figures from a financial table.
  #
  # Filings flatten tables into lines like "374.1 $ 325.9 Gross margin 49.0 %
  # 50.6 %"; they are worth indexing but useless as a summary bullet.
  def looks_like_table_row(text)
    tokens = split_words(text)
    return false if tokens.size < 4

    numeric = tokens.count do |t|
      t.gsub(TABLE_TOKEN_TRIM_RE, "").match?(TABLE_ROW_RE) || t.match?(/[[:digit:]]/)
    end
    numeric.fdiv(tokens.size) > 0.4
  end

  # True for Title Case section headings ("Results of Operations").
  def looks_like_heading(text)
    words = split_words(text).select { |w| w.match?(/\A[[:alpha:]]/) && w.length > 2 }
    return false if words.size < 2

    capitalised = words.count { |w| w.match?(/\A[[:upper:]]/) || HEADING_CONNECTORS.include?(w.downcase) }
    capitalised.fdiv(words.size) >= 0.75
  end

  # Remove a Title Case heading fused onto the front of a sentence.
  #
  # Flattened filings have no period after "Unregistered Sales of Equity
  # Securities and Use of Proceeds", so the heading runs into the paragraph
  # that follows and the sentence splitter cannot separate them. A run of three
  # or more capitalised words at the start (connectors allowed) is a heading.
  def strip_leading_heading(text)
    words = split_words(text)
    run = 0
    capitalised = 0
    words.each do |word|
      core = word.gsub(HEADING_WORD_TRIM_RE, "")
      break if core.empty?

      upper = core.match?(/\A[[:upper:]]/)
      break unless upper || HEADING_CONNECTORS.include?(core.downcase) || core.match?(/\A[[:digit:]]/)

      run += 1
      capitalised += 1 if upper
    end
    return words[run..].join(" ") if capitalised >= 3 && run < words.size
    return "" if capitalised >= 3 && run == words.size # the whole thing is a heading

    text
  end

  # Lowercased word tokens, punctuation dropped.
  def tokenize(text)
    (text || "").scan(WORD_RE).map(&:downcase)
  end

  def content_tokens(text)
    tokenize(text).reject { |t| STOPWORDS.include?(t) || t.length <= 2 || t.match?(/\A[[:digit:]]/) }
  end

  def sentences(text)
    raw = strip_ws(text || "").split(SENTENCE_RE).map { |s| strip_ws(s) }.reject(&:empty?)
    raw.select { |s| s.length > 2 }
  end

  # Return a polarity score in roughly [-1, 1].
  #
  # Handles negation ("not strong") and intensity ("significantly weaker") with a
  # three-token look-back, which is enough for the hedged register of filings.
  def score_sentiment(text)
    tokens = tokenize(text)
    return 0.0 if tokens.empty?

    total = 0.0
    hits = 0
    tokens.each_with_index do |token, i|
      weight = POSITIVE_LEXICON.fetch(token, 0.0)
      weight = -NEGATIVE_LEXICON.fetch(token, 0.0) if weight.zero?
      next if weight.zero?

      tokens[[0, i - 3].max...i].each do |prior|
        weight *= -0.85 if NEGATORS.include?(prior)
        weight *= INTENSIFIERS.fetch(prior, 1.0)
      end
      total += weight
      hits += 1
    end
    return 0.0 if hits.zero?

    # Normalise by a soft document length so a long bullish transcript does not
    # swamp a short bullish headline.
    denom = [hits, Math.sqrt(tokens.size)].max
    (total / (denom * 1.35)).clamp(-1.0, 1.0)
  end

  def sentiment_label(score)
    return "positive" if score >= 0.18
    return "negative" if score <= -0.18

    "neutral"
  end

  # Add lexicon synonyms for each term, preserving order and uniqueness.
  def expand_query_terms(terms)
    out = []
    seen = Set.new
    terms.each do |term|
      key = term.downcase
      [key, *SYNONYMS.fetch(key, [])].each do |candidate|
        out << candidate if seen.add?(candidate)
      end
    end
    out
  end

  # Top tf-idf unigrams and bigrams for a piece of text.
  #
  # Sublinear term frequency with a minimum-count floor on longer texts: without
  # the floor, every word that happens to appear exactly once ties on score and
  # the result degenerates into an alphabetical list of rare noise.
  def keywords(text, corpus: nil, limit: 8)
    tokens = content_tokens(text)
    return [] if tokens.empty?

    counts = tokens.tally
    min_count = tokens.size >= 90 ? 2 : 1
    candidates = counts.select { |_, c| c >= min_count }
    candidates = counts.dup if candidates.empty?

    idf = ->(token) { corpus ? corpus.idf(token) : 1.0 }

    scores = candidates.to_h { |token, count| [token, (1.0 + Math.log(count)) * idf.call(token)] }
    bigrams(tokens).tally.each do |gram, count|
      next if count < [2, min_count].max

      left, right = gram.split(" ", 2)
      scores[gram] = (1.0 + Math.log(count)) * 1.45 * (idf.call(left) + idf.call(right)) / 2
    end
    ranked = scores.sort_by { |token, score| [-score, -counts.fetch(token, 0), token] }
    ranked.first(limit)
  end

  # Extractive summary: rank sentences by keyword mass, position and query hit.
  #
  # Returns sentences in their original order so the summary still reads as prose.
  def summarize(text, limit: 4, query_terms: [])
    sents = sentences(text)
    return [] if sents.empty?
    return sents if sents.size <= limit

    weights = content_tokens(text).tally
    query_set = query_terms.map(&:downcase).to_set
    scored = []
    sents.each_with_index do |sentence, idx|
      toks = content_tokens(sentence)
      next if toks.empty? || looks_like_table_row(sentence)

      mass = toks.sum { |t| weights.fetch(t, 0) } / Math.sqrt(toks.size)
      position_bonus = idx.zero? ? 1.25 : (idx < 3 ? 1.1 : 1.0)
      query_bonus = toks.any? { |t| query_set.include?(t) } ? 1.5 : 1.0
      numeric_bonus = sentence.match?(/[[:digit:]]/) ? 1.15 : 1.0
      scored << [mass * position_bonus * query_bonus * numeric_bonus, idx, sentence]
    end
    # Python's sort is stable, so tied scores keep source order; Ruby's sort_by
    # is not, hence the index as the secondary key.
    top = scored.sort_by { |score, idx, _| [-score, idx] }.first(limit)
    top.sort_by { |_, idx, _| idx }.map { |_, _, sentence| sentence }
  end

  # Pull numeric KPIs out of narrative text with the sentence as context.
  def extract_kpis(text)
    found = []
    sents = sentences(text)
    sents = [text] if sents.empty?
    sents.each do |sentence|
      KPI_PATTERNS.each do |metric, pattern, unit|
        sentence.to_enum(:scan, pattern).map { Regexp.last_match }.each do |match|
          raw = match[1].delete(",")
          # "-$12 million" puts the sign before the currency symbol, outside the
          # number group; look at the three characters ahead of the number too.
          ahead = sentence[[match.begin(1) - 3, 0].max...match.begin(1)].to_s
          negative = raw.match?(/\A(?:-|−|negative)/i) || ahead.match?(/[-−][[:space:]]?\$?\z/)
          value = begin
            Float(raw.sub(/\A(?:-|−|negative[[:space:]]+)/i, ""))
          rescue ArgumentError
            next
          end
          value = -value if negative
          value *= 1000.0 if unit == "currency" && match[0].match?(BILLIONS_RE) # normalise to millions
          next unless kpi_value_plausible?(metric, unit, value, match[1])

          found << {
            metric: metric,
            value: value,
            unit: unit == "currency" ? "USDm" : unit,
            context: strip_ws(sentence)
          }
        end
      end
    end
    found
  end

  # Plausible ranges per metric. A value outside them is a parse, not a fact:
  # real filings produced "headcount = 2004" (from "the 2004 Stock Incentive
  # Plan") and "ebitda_margin = 120". Retention and growth may exceed 100%.
  KPI_BOUNDS = {
    "gross_margin" => (-100.0..100.0), "ebitda_margin" => (-100.0..100.0),
    "operating_margin" => (-100.0..100.0), "capex_intensity" => (0.0..100.0),
    "churn" => (0.0..100.0), "net_retention" => (0.0..300.0),
    "revenue_growth" => (0.0..1000.0), "revenue_decline" => (0.0..100.0)
  }.freeze

  # Amounts that can legitimately be negative: a cash outflow is still a fact.
  SIGNED_CURRENCY = %w[free_cash_flow].freeze

  def kpi_value_plausible?(metric, unit, value, raw)
    case unit
    when "%" then KPI_BOUNDS.fetch(metric, (-100.0..100.0)).cover?(value)
    # A four-digit count with no thousands separator that reads as a year is a year.
    when "count" then value >= 10 && !(raw.exclude?(",") && value.between?(1900, 2100))
    else SIGNED_CURRENCY.include?(metric) || value >= 0
    end
  end

  # a, b are Hash{String => Numeric} term vectors (see .vector).
  def cosine_similarity(a, b)
    return 0.0 if a.nil? || a.empty? || b.nil? || b.empty?

    common = a.keys & b.keys
    num = common.sum { |t| a[t] * b[t] }
    return 0.0 if num.zero?

    den = Math.sqrt(a.values.sum { |v| v * v }) * Math.sqrt(b.values.sum { |v| v * v })
    den.zero? ? 0.0 : num / den
  end

  def vector(text, corpus = nil)
    counts = content_tokens(text).tally
    return counts if corpus.nil?

    counts.to_h { |t, c| [t, c * corpus.idf(t)] }
  end

  # Themes over-represented in ``recent`` text versus a ``baseline`` period.
  #
  # Lift is a ratio of normalised document frequencies, which is what makes a
  # theme read as "emerging" rather than merely common. Bigrams are scored
  # alongside unigrams because "interconnection queue" is a theme while
  # "queue" on its own is barely a word.
  def theme_trends(recent, baseline, limit: 10, min_recent: 2)
    recent_counts = Hash.new(0)
    recent_docs = 0
    recent.each do |text|
      recent_docs += 1
      theme_features(text).each { |feature| recent_counts[feature] += 1 }
    end
    base_counts = Hash.new(0)
    base_docs = 0
    baseline.each do |text|
      base_docs += 1
      theme_features(text).each { |feature| base_counts[feature] += 1 }
    end

    recent_docs = [1, recent_docs].max
    base_docs = [1, base_docs].max
    # Require more supporting documents as the window grows: in a large window a
    # phrase appearing twice is noise, in a small one it is the whole signal.
    # (Python's round() is half-to-even: 18 docs -> 1.5 -> 2, 30 docs -> 2.5 -> 2.)
    rounded = (recent_docs / 12.0).round(half: :even)
    floor = [min_recent, rounded.zero? ? min_recent : rounded].max
    rows = []
    recent_counts.each do |token, count|
      next if count < floor

      recent_rate = count.fdiv(recent_docs)
      base_rate = base_counts[token].fdiv(base_docs)
      lift = base_rate.zero? ? (1 + count).to_f : recent_rate / base_rate
      is_phrase = token.include?(" ")
      rows << {
        theme: token,
        mentions: count,
        prior_mentions: base_counts[token],
        lift: py_round(lift, 2),
        # Phrases are more informative per character than single tokens, and
        # a theme carried by more documents outranks one carried by two.
        rank: py_round(lift * (is_phrase ? 1.25 : 1.0) * (1 + 0.4 * Math.log(count)), 3)
      }
    end
    rows.sort_by! { |r| theme_sort_key(r) }
    dedupe_themes(rows, limit)
  end

  # --- helpers -------------------------------------------------------------

  # Features of one document for theme_trends: prose-only unigrams and bigrams.
  #
  # Build phrases inside prose sentences only. Bigrams taken across the
  # whole token stream straddle headings and table-of-contents lines, and
  # "Risk Factors / Unregistered Sales of Equity" became the theme
  # "factors sales" in a real filing corpus.
  def theme_features(text)
    found = Set.new
    sents = sentences(text)
    sents = [text] if sents.empty?
    sents.each do |sentence|
      next if looks_like_table_row(sentence) || looks_like_heading(sentence)

      sentence = strip_leading_heading(sentence)
      tokens = content_tokens(sentence)
      next if tokens.size < 3 # a fragment, not a sentence

      found.merge(tokens)
      found.merge(bigrams(tokens))
    end
    found
  end

  # Drop themes contained in another accepted theme.
  #
  # Without this the top of the list reads "constraint pricing, transmission
  # constraint, constraint, transmission" — four slots spent on one idea.
  # Phrases are considered first, then single tokens that no accepted phrase
  # already covers.
  def dedupe_themes(rows, limit)
    accepted = [] # [Set of theme words, row]
    consider = lambda do |row|
      tokens = row[:theme].split(" ").to_set
      next if accepted.any? { |existing, _| tokens <= existing || existing <= tokens }

      accepted << [tokens, row]
    end

    rows.each { |row| consider.call(row) if row[:theme].include?(" ") }
    rows.each { |row| consider.call(row) unless row[:theme].include?(" ") }
    chosen = accepted.map { |_, row| row }
    chosen.sort_by { |r| theme_sort_key(r) }.first(limit)
  end

  def theme_sort_key(row)
    [-row[:rank].to_f, -row[:mentions].to_i, row[:theme].to_s]
  end

  def bigrams(tokens)
    tokens.each_cons(2).map { |a, b| "#{a} #{b}" }
  end

  # Python's str.split(): Unicode whitespace, no empty fields.
  def split_words(text)
    text.split(WS_RE).reject(&:empty?)
  end

  # Python's str.strip(): Unicode whitespace at both ends.
  def strip_ws(text)
    text.gsub(EDGE_WS_RE, "")
  end

  # Python's round(x, n): round the exact binary value half-to-even and return
  # the nearest float. Ruby's Float#round rounds the shortest decimal rendering
  # half-up instead (2.675 -> 2.68 in Ruby, 2.67 in Python). Lift and rank are
  # sort keys, so they must tie-break exactly as the reference does.
  def py_round(value, digits)
    scale = 10**digits
    Rational((value.to_r * scale).round(half: :even), scale).to_f
  end

  private_class_method :theme_features, :dedupe_themes, :theme_sort_key, :bigrams,
                       :split_words, :strip_ws, :py_round
end
