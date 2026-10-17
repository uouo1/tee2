# frozen_string_literal: true

require "erb"

# The research search engine.
#
# A query goes through four stages:
#
# 1. **Parse** — quoted phrases, `-exclusions`, `OR` groups and field filters
#    (`type:filing`, `ticker:NVG`, `date:2026-07`) are pulled out of the raw string.
# 2. **Expand** — each bare term optionally picks up lexicon synonyms, because the
#    vocabulary gap between "guidance" and "outlook" is what makes naive search on
#    filings feel broken.
# 3. **Rank** — BM25 from FTS5, re-weighted for recency and document type, so a
#    two-year-old press release does not outrank last week's transcript.
# 4. **Present** — highlighted snippets, facet counts and an extractive summary of
#    the top matches.
#
# Ranking is per *document*, not per chunk (docs/RAILS_PORT.md items 5 and 21):
# the reference ranked a top-k of chunks (`min(limit * 6 + offset, 600)`) and then
# collapsed them to documents, so `total_documents` changed with the page size
# and a broad query's later pages were simply missing. Here one SQL takes the
# best (lowest) bm25 per document over every matching chunk, Ruby applies the
# type and recency weights, sorts, counts the true total and only then paginates.
module Search
  FIELD_RE = /\b(type|ticker|company|source|author|sentiment|date):("[^"]+"|\S+)/i
  TOKEN_RE = /"[^"]*"|\S+/

  # Document types are weighted by how much signal analysts actually get from them.
  DOC_TYPE_WEIGHT = {
    "transcript" => 1.15,
    "filing" => 1.10,
    "research" => 1.05,
    "expert-call" => 1.05,
    "investor-day" => 1.0,
    "press-release" => 0.92,
    "news" => 0.90,
    "memo" => 0.95
  }.freeze
  HALF_LIFE_DAYS = 420.0

  # Search behaviour (argos/config.py).
  SNIPPET_TOKENS = 34
  MAX_RESULTS = 200

  # Sentiment labels share Nlp.sentiment_label's ±0.18 thresholds; the filter and
  # the facet both read documents.sentiment so their counts agree.
  SENTIMENT_THRESHOLD = 0.18
  DOC_SENTIMENT = "COALESCE(d.sentiment, 0.0)"

  CORPUS_SAMPLE = 1500

  # FTS5 highlight markers: U+2991 / U+2992 never occur in filings, so they
  # survive HTML escaping and can be swapped for <mark> afterwards.
  OPEN_MARK = "⦑"
  CLOSE_MARK = "⦒"

  BASE_FROM = <<~SQL
    FROM chunks_fts f
    JOIN chunks ch ON ch.id = f.rowid
    JOIN documents d ON d.id = ch.document_id
    LEFT JOIN companies c ON c.id = d.company_id
  SQL

  BROWSE_FROM = <<~SQL
    FROM chunks ch
    JOIN documents d ON d.id = ch.document_id
    LEFT JOIN companies c ON c.id = d.company_id
  SQL

  SELECT_COLS = <<~SQL
    ch.id AS chunk_id, ch.document_id, ch.seq, ch.speaker, ch.sentiment AS chunk_sentiment,
    d.title, d.doc_type, d.source, d.author, d.published_at, d.url,
    d.sentiment AS doc_sentiment, d.word_count,
    c.ticker, c.name AS company, c.sector
  SQL

  # A raw query string decomposed into something executable. `fields` maps a
  # field name (symbol) to every value given for it, so "ticker:ITRI ticker:BMI"
  # keeps both tickers.
  ParsedQuery = Struct.new(:raw, :terms, :phrases, :or_groups, :excluded, :fields, keyword_init: true) do
    def initialize(raw: "", terms: [], phrases: [], or_groups: [], excluded: [], fields: {})
      super
    end

    def empty?
      terms.empty? && phrases.empty? && or_groups.empty?
    end

    def all_terms
      terms + phrases + or_groups.flatten
    end
  end

  @corpus_cache = {}
  @corpus_lock = Mutex.new

  module_function

  def parse_query(raw)
    parsed = ParsedQuery.new(raw: raw.to_s.strip)
    remainder = parsed.raw.dup

    parsed.raw.scan(FIELD_RE) do
      match = Regexp.last_match
      key = match[1].downcase.to_sym
      value = strip_quotes(match[2])
      values = (parsed.fields[key] ||= [])
      values << value unless value.empty? || values.include?(value)
      remainder = remainder.gsub(match[0], " ")
    end

    tokens = remainder.scan(TOKEN_RE).reject { |t| t.strip.empty? }
    i = 0
    while i < tokens.size
      token = tokens[i]
      upper = token.upcase
      if %w[OR AND].include?(upper)
        i += 1
        next
      end
      negated = token.start_with?("-") && token.size > 1
      clean = negated ? token[1..] : token
      is_phrase = clean.start_with?('"') && clean.end_with?('"') && clean.size > 2
      value = strip_quotes(clean)
      if value.empty?
        i += 1
        next
      end
      if negated
        parsed.excluded << value
        i += 1
        next
      end
      # Look ahead for an explicit OR group: a OR b OR c
      if i + 2 < tokens.size && tokens[i + 1].upcase == "OR"
        group = [value]
        j = i + 1
        while j + 1 < tokens.size && tokens[j].upcase == "OR"
          group << strip_quotes(tokens[j + 1])
          j += 2
        end
        parsed.or_groups << group.reject(&:empty?)
        i = j
        next
      end
      (is_phrase ? parsed.phrases : parsed.terms) << value
      i += 1
    end
    parsed
  end

  # Quote a term/phrase for FTS5, neutralising embedded quotes and operators.
  def fts_quote(value)
    cleaned = value.to_s.gsub(/["*^]/, " ").strip.gsub(/\s+/, " ")
    cleaned.empty? ? "" : %("#{cleaned}")
  end

  # Render a parsed query as an FTS5 MATCH expression.
  def build_match_expression(parsed, expand: true)
    clauses = []

    parsed.phrases.each do |phrase|
      quoted = fts_quote(phrase)
      clauses << quoted unless quoted.empty?
    end

    parsed.terms.each do |term|
      variants = expand ? Nlp.expand_query_terms([term]) : [term]
      quoted = variants.map { |v| fts_quote(v) }.reject(&:empty?)
      next if quoted.empty?

      clauses << (quoted.size == 1 ? quoted.first : "(#{quoted.join(' OR ')})")
    end

    parsed.or_groups.each do |group|
      variants = group.flat_map { |term| expand ? Nlp.expand_query_terms([term]) : [term] }
      quoted = variants.map { |v| fts_quote(v) }.reject(&:empty?)
      clauses << "(#{quoted.join(' OR ')})" unless quoted.empty?
    end

    expression = clauses.join(" AND ")
    excluded = parsed.excluded.map { |e| fts_quote(e) }.reject(&:empty?)
    expression += " NOT #{excluded.join(' NOT ')}" if !expression.empty? && excluded.any?
    expression
  end

  def recency_weight(published_at, today = nil)
    published = published_at.is_a?(Date) ? published_at : Date.iso8601(published_at.to_s[0, 10])
    days = [0, ((today || Date.today) - published).to_i].max
    0.55 + (0.45 * Math.exp(-days / HALF_LIFE_DAYS))
  rescue ArgumentError, TypeError
    0.8
  end

  # Escape a snippet for HTML, then re-apply the FTS highlight markers.
  def highlight(raw_snippet)
    escaped = ERB::Util.html_escape(raw_snippet.to_s).to_str
    escaped = escaped.gsub(OPEN_MARK, "<mark>").gsub(CLOSE_MARK, "</mark>")
    escaped.tr("\n", " ")
  end

  # Turn a `date:` value into an inclusive [from, to] pair of ISO dates.
  #
  # "2026" is that calendar year, "2026-07" that month, "2026-07-15" that day,
  # and "a..b" runs from the start of a to the end of b (either side may be
  # left open). Anything unparseable returns nil and is ignored rather than
  # silently matching nothing.
  def parse_date_range(value)
    text = value.to_s.strip
    if text.include?("..")
      left, right = text.split("..", 2).map(&:strip)
      from = left.empty? ? nil : date_bounds(left)&.first
      to = right.to_s.empty? ? nil : date_bounds(right)&.last
      return nil if (from.nil? && !left.empty?) || (to.nil? && !right.to_s.empty?) || (from.nil? && to.nil?)

      [from, to]
    else
      date_bounds(text)
    end
  end

  def date_bounds(text)
    case text
    when /\A(\d{4})\z/
      year = Regexp.last_match(1).to_i
      [Date.new(year, 1, 1), Date.new(year, 12, 31)]
    when /\A(\d{4})-(\d{1,2})\z/
      start = Date.new(Regexp.last_match(1).to_i, Regexp.last_match(2).to_i, 1)
      [start, start.end_of_month]
    when /\A\d{4}-\d{1,2}-\d{1,2}\z/
      day = Date.new(*text.split("-").map(&:to_i))
      [day, day]
    end
  rescue Date::Error, ArgumentError
    nil
  end

  # Build the WHERE fragment shared by search and facet counting.
  #
  # Inline fields and explicit filters merge per key, the explicit filter winning
  # (as in the reference). Each field may carry several values, OR-ed within the
  # field and AND-ed across fields. `date:` ranges and `date_from`/`date_to` are
  # all applied, so the tighter bound wins.
  def filter_sql(filters, parsed = nil)
    where = []
    params = []
    fields = parsed ? parsed.fields.transform_keys(&:to_sym) : {}
    explicit = (filters || {}).to_h.transform_keys(&:to_sym).reject { |_, v| blank_filter?(v) }
    merged = fields.merge(explicit)

    types = list(merged[:doc_type].presence || merged[:type])
    if types.any?
      where << "d.doc_type IN (#{placeholders(types)})"
      params.concat(types)
    end

    tickers = list(merged[:ticker])
    if tickers.any?
      where << "c.ticker IN (#{placeholders(tickers)})"
      params.concat(tickers.map(&:upcase))
    end

    { company: "c.name", source: "d.source", author: "d.author" }.each do |key, column|
      values = list(merged[key])
      next if values.empty?

      where << "(#{values.map { "#{column} LIKE ?" }.join(' OR ')})"
      params.concat(values.map { |v| "%#{v}%" })
    end

    sectors = list(merged[:sector])
    if sectors.any?
      where << "c.sector IN (#{placeholders(sectors)})"
      params.concat(sectors)
    end

    ranges = list(merged[:date]).filter_map { |v| parse_date_range(v) }
    if ranges.any?
      clauses = ranges.map do |from, to|
        parts = []
        if from
          parts << "d.published_at >= ?"
          params << from.iso8601
        end
        if to
          parts << "d.published_at <= ?"
          params << to.iso8601
        end
        "(#{parts.join(' AND ')})"
      end
      where << "(#{clauses.join(' OR ')})"
    end

    if merged[:date_from].present?
      where << "d.published_at >= ?"
      params << merged[:date_from].to_s[0, 10]
    end
    if merged[:date_to].present?
      where << "d.published_at <= ?"
      params << merged[:date_to].to_s[0, 10]
    end

    # Document-level, like the sentiment facet: a chunk-level filter returned
    # documents the facet counted under another label.
    sentiment_clauses = list(merged[:sentiment]).map(&:downcase).uniq.filter_map do |label|
      case label
      when "positive" then "#{DOC_SENTIMENT} >= #{SENTIMENT_THRESHOLD}"
      when "negative" then "#{DOC_SENTIMENT} <= -#{SENTIMENT_THRESHOLD}"
      when "neutral" then "(#{DOC_SENTIMENT} > -#{SENTIMENT_THRESHOLD} AND #{DOC_SENTIMENT} < #{SENTIMENT_THRESHOLD})"
      end
    end
    where << "(#{sentiment_clauses.join(' OR ')})" if sentiment_clauses.any?

    if merged[:min_document_id].present?
      where << "d.id > ?"
      params << merged[:min_document_id].to_i
    end

    [where.join(" AND "), params]
  end

  # Document-frequency stats for the corpus, cached per database.
  #
  # tf-idf keywording is only as good as its idf: without corpus statistics,
  # "adjusted" and "quarter" outrank "interconnection". The cache is invalidated
  # whenever the document count changes, which is the cheap proxy for ingest.
  def corpus_stats
    key = ActiveRecord::Base.connection_db_config.database.to_s
    doc_count = connection.select_value("SELECT COUNT(*) FROM documents").to_i
    @corpus_lock.synchronize do
      cached = @corpus_cache[key]
      return cached[:corpus] if cached && cached[:doc_count] == doc_count

      corpus = Nlp::Corpus.new
      bodies = connection.select_values(
        sql(["SELECT body FROM documents ORDER BY published_at DESC LIMIT ?", CORPUS_SAMPLE])
      )
      bodies.each { |body| corpus.add(body) }
      @corpus_cache[key] = { doc_count: doc_count, corpus: corpus }
      corpus
    end
  end

  def reset_corpus_cache!
    @corpus_lock.synchronize { @corpus_cache.clear }
  end

  # Run a research query and return results, facets and a summary.
  def search(q = "", filters = {}, limit: 25, offset: 0, expand: true, summarize: true, today: Date.today)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    filters = (filters || {}).to_h.transform_keys(&:to_sym)
    parsed = parse_query(q)
    match_expr = build_match_expression(parsed, expand: expand)
    limit = limit.to_i.clamp(1, MAX_RESULTS)
    offset = [offset.to_i, 0].max
    where_sql, where_params = filter_sql(filters, parsed)

    if match_expr.empty?
      total, page = browse(where_sql, where_params, limit: limit, offset: offset)
    else
      total, page = ranked(match_expr, where_sql, where_params, limit: limit, offset: offset, today: today)
    end

    result = {
      query: q,
      parsed: {
        terms: parsed.terms, phrases: parsed.phrases, or_groups: parsed.or_groups,
        excluded: parsed.excluded, fields: parsed.fields
      },
      match_expression: match_expr,
      expanded: expand && !match_expr.empty?,
      total_documents: total,
      returned: page.size,
      offset: offset,
      results: page,
      facets: facets(parsed, filters, match_expr)
    }
    result[:summary] = summarize_results(page, parsed) if summarize && page.any?
    result[:took_ms] = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round(1)
    result
  end

  # Relevance mode: one row per matching document carrying its best passage.
  def ranked(match_expr, where_sql, where_params, limit:, offset:, today:)
    # FTS5 auxiliary functions cannot run inside an aggregate, so the matching
    # passages are scored in a MATERIALIZED CTE (which stops SQLite flattening
    # it back into the GROUP BY) and grouped outside it. SQLite's bare-column
    # rule then does the rest: with exactly one MIN() in the select, the bare
    # chunk_id comes from the row that holds the minimum, i.e. the best passage.
    # The document columns are constant within a group.
    hits = +<<~SQL
      SELECT ch.id AS chunk_id, ch.document_id AS document_id, bm25(chunks_fts) AS bm25,
             d.doc_type AS doc_type, d.published_at AS published_at
      #{BASE_FROM}
      WHERE chunks_fts MATCH ?
    SQL
    params = [match_expr]
    unless where_sql.empty?
      hits << " AND #{where_sql}"
      params.concat(where_params)
    end
    grouped = <<~SQL
      WITH hits AS MATERIALIZED (#{hits})
      SELECT document_id, chunk_id, MIN(bm25) AS bm25, COUNT(*) AS match_count, doc_type, published_at
      FROM hits GROUP BY document_id
    SQL
    rows = select_rows(grouped, params)

    scored = rows.map do |row|
      weight = DOC_TYPE_WEIGHT.fetch(row[:doc_type], 1.0) * recency_weight(row[:published_at], today)
      {
        document_id: row[:document_id].to_i,
        chunk_id: row[:chunk_id].to_i,
        match_count: row[:match_count].to_i,
        published_at: row[:published_at].to_s,
        score: (-row[:bm25].to_f * weight).round(4, half: :even)
      }
    end
    scored.sort_by! { |r| [-r[:score], r[:published_at], r[:document_id]] }
    page = scored[offset, limit] || []
    return [scored.size, []] if page.empty?

    # snippet() needs the MATCH in the same statement, so the page's passages are
    # fetched again under it, restricted to their rowids.
    chunk_ids = page.map { |r| r[:chunk_id] }
    detail = select_rows(<<~SQL, [match_expr, *chunk_ids])
      SELECT #{SELECT_COLS},
             snippet(chunks_fts, 0, char(10641), char(10642), '…', #{SNIPPET_TOKENS}) AS snip
      #{BASE_FROM}
      WHERE chunks_fts MATCH ? AND f.rowid IN (#{placeholders(chunk_ids)})
    SQL
    by_chunk = detail.index_by { |row| row[:chunk_id].to_i }

    results = page.filter_map do |rank|
      row = by_chunk[rank[:chunk_id]]
      next unless row

      present(row, score: rank[:score], match_count: rank[:match_count])
    end
    [scored.size, results]
  end

  # No query text: browse mode, newest first, filters still apply.
  #
  # Browse mode is a reverse-chronological feed; relevance weighting there would
  # quietly reorder "newest first" into something else, so SQL orders and pages it.
  def browse(where_sql, where_params, limit:, offset:)
    condition = +"WHERE ch.seq = 0"
    condition << " AND #{where_sql}" unless where_sql.empty?
    total = connection.select_value(
      sql(["SELECT COUNT(DISTINCT d.id) #{BROWSE_FROM} #{condition}", *where_params])
    ).to_i
    rows = select_rows(<<~SQL, [*where_params, limit, offset])
      SELECT #{SELECT_COLS}, substr(ch.text, 1, 320) AS snip
      #{BROWSE_FROM}
      #{condition}
      ORDER BY d.published_at DESC, d.id DESC
      LIMIT ? OFFSET ?
    SQL
    [total, rows.map { |row| present(row, score: 0.0, match_count: 1) }]
  end

  # Shape one result row for the views and the API.
  def present(row, score:, match_count:)
    snip = row.delete(:snip)
    row[:chunk_id] = row[:chunk_id].to_i
    row[:document_id] = row[:document_id].to_i
    row[:published_at] = to_date(row[:published_at])
    row[:score] = score
    row[:snippet_html] = highlight(snip || "")
    row[:sentiment_label] = Nlp.sentiment_label(row[:chunk_sentiment].to_f)
    # The passage label above is the reference's; the document label is what the
    # sentiment filter and facet count, so expose it beside it.
    row[:doc_sentiment_label] = Nlp.sentiment_label(row[:doc_sentiment].to_f)
    # How many passages matched — "7 matching passages" is itself a research signal.
    row[:match_count] = match_count
    row
  end

  # Facet counts over the documents that match the query and filters.
  def facets(parsed, filters, match_expr)
    where_sql, where_params = filter_sql(filters, parsed)
    cols = "SELECT DISTINCT d.id, d.doc_type, d.published_at, #{DOC_SENTIMENT} AS sentiment, " \
           "c.ticker, c.name AS company, c.sector"
    if match_expr.to_s.empty?
      source = +"#{cols} #{BROWSE_FROM} WHERE 1=1"
      params = []
    else
      source = +"#{cols} #{BASE_FROM} WHERE chunks_fts MATCH ?"
      params = [match_expr]
    end
    unless where_sql.empty?
      source << " AND #{where_sql}"
      params.concat(where_params)
    end

    group = lambda do |column, label, limit = 12|
      select_rows(<<~SQL, params).map { |r| { label: label, value: r[:value], count: r[:count].to_i } }
        SELECT #{column} AS value, COUNT(*) AS count FROM (#{source})
        WHERE #{column} IS NOT NULL GROUP BY 1 ORDER BY count DESC, value LIMIT #{limit}
      SQL
    end

    sentiment_sql = <<~SQL
      SELECT CASE WHEN sentiment >= #{SENTIMENT_THRESHOLD} THEN 'positive'
                  WHEN sentiment <= -#{SENTIMENT_THRESHOLD} THEN 'negative'
                  ELSE 'neutral' END AS value,
             COUNT(*) AS count
      FROM (#{source}) GROUP BY 1 ORDER BY count DESC
    SQL
    year_sql = "SELECT substr(published_at, 1, 4) AS value, COUNT(*) AS count FROM (#{source}) GROUP BY 1 ORDER BY value DESC"
    {
      doc_type: group.call("doc_type", "Document type"),
      ticker: group.call("ticker", "Company"),
      sector: group.call("sector", "Sector"),
      year: select_rows(year_sql, params).map { |r| { label: "Year", value: r[:value], count: r[:count].to_i } },
      sentiment: select_rows(sentiment_sql, params).map { |r| { label: "Sentiment", value: r[:value], count: r[:count].to_i } }
    }
  end

  # Build a cited summary across the top hits.
  #
  # Each bullet keeps its document id so the UI (and the pitch book) can trace
  # the claim back to a source — a summary without provenance is not usable in
  # banker-facing material.
  def summarize_results(results, parsed, bullets: 5)
    chunk_ids = results.first(12).map { |r| r[:chunk_id].to_i }
    return { bullets: [], themes: [], sentiment: 0.0, sentiment_label: "neutral" } if chunk_ids.empty?

    rows = select_rows(<<~SQL, chunk_ids)
      SELECT ch.id, ch.text, ch.sentiment, ch.speaker,
             d.id AS document_id, d.title, d.published_at, d.doc_type, c.ticker
      FROM chunks ch JOIN documents d ON d.id = ch.document_id
      LEFT JOIN companies c ON c.id = d.company_id
      WHERE ch.id IN (#{placeholders(chunk_ids)})
    SQL
    by_id = rows.index_by { |r| r[:id].to_i }
    terms = parsed.all_terms

    picked = []
    seen_sentences = Set.new
    chunk_ids.each do |chunk_id|
      row = by_id[chunk_id]
      next unless row
      # A question put by an analyst, or the operator's intro, is not a finding.
      next if boilerplate_speaker?(row[:speaker])

      candidates = Nlp.summarize(row[:text], limit: 4, query_terms: terms).presence || [row[:text]]
      statements = candidates.reject do |c|
        c.rstrip.end_with?("?") || Nlp.looks_like_table_row(c) || Nlp.looks_like_heading(c)
      end
      # A fragment ("Competitive renewals.") or a section heading ("Bookings
      # and Backlog of Orders") is technically the top-ranked sentence and
      # useless as a finding: require a clause's worth of words or skip.
      substantial = statements.select { |c| c.split.size >= 8 }.map { |c| Nlp.strip_leading_heading(c) }
      substantial = substantial.select { |c| c.split.size >= 8 }
      next if substantial.empty?

      sentence = substantial.first
      sentence = sentence[0].upcase + sentence[1..] # a stripped heading leaves a lowercase start
      # Near-identical boilerplate across documents (the same risk-factor
      # paragraph, the same wire copy) would otherwise fill the summary with
      # one claim repeated five times.
      fingerprint = sentence.downcase.split.join(" ")[0, 160]
      next unless seen_sentences.add?(fingerprint)

      picked << {
        text: sentence.strip[0, 400],
        document_id: row[:document_id].to_i,
        title: row[:title],
        ticker: row[:ticker],
        doc_type: row[:doc_type],
        published_at: to_date(row[:published_at]),
        chunk_id: chunk_id,
        sentiment: row[:sentiment].to_f.round(3, half: :even)
      }
      break if picked.size >= bullets
    end

    unique_texts = {}
    chunk_ids.each do |chunk_id|
      row = by_id[chunk_id]
      unique_texts[row[:text].downcase.split.join(" ")[0, 200]] ||= row[:text] if row
    end
    blob = unique_texts.values.join(" ")
    sentiments = chunk_ids.filter_map { |c| by_id[c] && by_id[c][:sentiment].to_f }
    mean = sentiments.empty? ? 0.0 : sentiments.sum / sentiments.size
    {
      bullets: picked,
      themes: Nlp.keywords(blob, corpus: corpus_stats, limit: 10).map { |t, w| { theme: t, weight: w.round(2, half: :even) } },
      sentiment: mean.round(3, half: :even),
      sentiment_label: Nlp.sentiment_label(mean)
    }
  end

  def boilerplate_speaker?(speaker)
    return false if speaker.blank?

    lowered = speaker.downcase
    %w[operator analyst interviewer moderator].any? { |word| lowered.include?(word) }
  end

  # Full document view: metadata, chunks, extracted KPIs, summary, neighbours.
  def get_document(document_id, query_terms: [])
    rows = select_rows(<<~SQL, [document_id.to_i])
      SELECT d.*, c.ticker, c.name AS company, c.sector, c.industry
      FROM documents d LEFT JOIN companies c ON c.id = d.company_id
      WHERE d.id = ?
    SQL
    return nil if rows.empty?

    record = rows.first
    record[:published_at] = to_date(record[:published_at])
    record[:chunks] = select_rows(
      "SELECT id, seq, speaker, text, sentiment FROM chunks WHERE document_id = ? ORDER BY seq", [document_id.to_i]
    )
    record[:chunks].each { |chunk| chunk[:sentiment_label] = Nlp.sentiment_label(chunk[:sentiment].to_f) }
    record[:kpis] = select_rows(
      "SELECT metric, value, unit, period, context, chunk_id FROM kpis WHERE document_id = ? ORDER BY metric",
      [document_id.to_i]
    )
    record[:summary] = Nlp.summarize(record[:body], limit: 5, query_terms: query_terms)
    record[:keywords] = Nlp.keywords(record[:body], corpus: corpus_stats, limit: 12)
                           .map { |t, w| { theme: t, weight: w.round(2, half: :even) } }
    record[:sentiment_label] = Nlp.sentiment_label(record[:sentiment].to_f)
    record[:similar] = similar_documents(document_id, limit: 5)
    record
  end

  # Nearest neighbours by tf-idf cosine over document bodies.
  #
  # Scoped to the same sector (or same company when the document has no sector)
  # to keep the candidate set small enough to score in-process.
  def similar_documents(document_id, limit: 5)
    target = select_rows(<<~SQL, [document_id.to_i]).first
      SELECT d.id, d.body, d.company_id, c.sector
      FROM documents d LEFT JOIN companies c ON c.id = d.company_id WHERE d.id = ?
    SQL
    return [] unless target

    candidates =
      if target[:sector].present?
        select_rows(<<~SQL, [document_id.to_i, target[:sector]])
          SELECT d.id, d.title, d.body, d.doc_type, d.published_at, c.ticker
          FROM documents d LEFT JOIN companies c ON c.id = d.company_id
          WHERE d.id != ? AND (c.sector = ? OR c.sector IS NULL)
          ORDER BY d.published_at DESC LIMIT 400
        SQL
      else
        select_rows(<<~SQL, [document_id.to_i])
          SELECT d.id, d.title, d.body, d.doc_type, d.published_at, c.ticker
          FROM documents d LEFT JOIN companies c ON c.id = d.company_id
          WHERE d.id != ? ORDER BY d.published_at DESC LIMIT 400
        SQL
      end

    corpus = corpus_stats
    target_vec = Nlp.vector(target[:body], corpus)
    scored = candidates.filter_map do |row|
      score = Nlp.cosine_similarity(target_vec, Nlp.vector(row[:body], corpus))
      next if score <= 0.02

      {
        document_id: row[:id].to_i, title: row[:title], doc_type: row[:doc_type],
        published_at: to_date(row[:published_at]), ticker: row[:ticker], similarity: score.round(3, half: :even)
      }
    end
    scored.sort_by { |r| -r[:similarity] }.first(limit)
  end

  # --- helpers -------------------------------------------------------------

  def connection
    ActiveRecord::Base.connection
  end

  def sql(array)
    ActiveRecord::Base.sanitize_sql_array(array)
  end

  def select_rows(statement, params = [])
    connection.select_all(sql([statement, *params])).to_a.map(&:symbolize_keys)
  end

  def placeholders(values)
    Array.new(values.size, "?").join(",")
  end

  def list(value)
    Array(value).flatten.map { |v| v.to_s.strip }.reject(&:empty?)
  end

  def blank_filter?(value)
    value.nil? || value == "" || (value.respond_to?(:empty?) && value.empty?)
  end

  def strip_quotes(text)
    text.to_s.gsub(/\A"+|"+\z/, "").strip
  end

  def to_date(value)
    return value if value.nil? || value.is_a?(Date)

    Date.iso8601(value.to_s[0, 10])
  rescue Date::Error
    value
  end

  private_class_method :connection, :sql, :select_rows, :placeholders, :list, :blank_filter?,
                       :strip_quotes, :to_date, :ranked, :browse, :present, :date_bounds
end
