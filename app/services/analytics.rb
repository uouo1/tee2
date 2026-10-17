# frozen_string_literal: true

# Aggregations that sit on top of the corpus: profiles, trends, alerts.
#
# These are the views an analyst opens before they search for anything — what has
# changed, which companies are talking about what, and whether the tone of a name
# is drifting. They are also the inputs the pitch book generator reads when it
# writes the market-overview and executive-summary slides.
#
# Port of argos/analytics.py, with three deliberate changes from the October 2026
# audit (docs/RAILS_PORT.md items 19 and 20, plus the alert count):
#
# * themes pass a filing-boilerplate stoplist before they are returned;
# * a KPI's "latest" value prefers a company-level sentence over a segment
#   column or a flattened table row, and says which it used and when;
# * an alert reports the true number of new matching documents, not the size of
#   the page of hits it shows.
#
# "As of" is always the newest document date, never today: a demo or a stale
# corpus must read the same on any day. An empty corpus has no as-of date (nil,
# rendered "n/a") rather than an invented one.
module Analytics
  KPI_LABELS = {
    "revenue_growth" => "Revenue growth",
    "revenue_decline" => "Revenue decline",
    "gross_margin" => "Gross margin",
    "ebitda_margin" => "EBITDA margin",
    "operating_margin" => "Operating margin",
    "net_retention" => "Net dollar retention",
    "churn" => "Churn",
    "arr" => "ARR",
    "backlog" => "Backlog / RPO",
    "headcount" => "Headcount",
    "free_cash_flow" => "Free cash flow",
    "capex_intensity" => "Capex intensity"
  }.freeze

  # Words that are structural in financial statements rather than signs of what a
  # company is talking about. On a real filing corpus the trending list read
  # "loss net", "comprehensive income", "foreign currency" and "file rule": the
  # same statement captions in every 10-Q, surfacing only because of which forms
  # happened to fall inside the window. Nlp::STOPWORDS already drops some of
  # these from tokenisation; the rest are legitimate words in prose (so Nlp keeps
  # them for search and summaries) but never a theme on their own or in a pair.
  THEME_BOILERPLATE = Set.new(%w[
    file files filed filing rule rules provided provide provides report reports reported
    stock stockholders shareholders net loss losses income comprehensive adjustment adjustments
    accounting standard standards foreign currency currencies item items table contents
    fasb asu topic n/a
  ]).freeze
  THEME_STOPLIST = (Nlp::STOPWORDS | THEME_BOILERPLATE).freeze

  # A KPI sentence that names a reporting segment or product line describes part
  # of the company. Itron's "gross margin 29.9%" was a segment column (Device
  # Solutions); the company-level adjusted figure was 41.4%.
  SEGMENT_RE = /\b(?:segments?|divisions?|solutions|networked|devices?|outcomes)\b/i
  ADJUSTED_RE = /\b(?:adjusted|non-gaap|non gaap)\b/i
  GAAP_RE = /\bgaap\b/i

  # Theme candidates asked of Nlp before the stoplist is applied, so that
  # dropping boilerplate does not leave the list short.
  THEME_CANDIDATES = 500

  # Days per month used to turn "24 months" into a cutoff, as in the reference.
  DAYS_PER_MONTH = 30.44

  module_function

  # Landing-page state: corpus size, coverage, tone, what is new.
  def overview
    as_of = latest_corpus_date
    mean = Document.average(:sentiment)
    {
      as_of: as_of,
      counts: {
        documents: Document.count,
        chunks: Chunk.count,
        companies: Company.count,
        kpis: Kpi.count,
        pitchbooks: Pitchbook.count,
        transactions: Transaction.count
      },
      by_type: Document.group(:doc_type).count
                       .map { |value, count| { value: value, count: count } }
                       .sort_by { |row| [-row[:count], row[:value].to_s] },
      coverage: rows(<<~SQL).map { |r| r.merge(latest: to_date(r[:latest])) },
        SELECT c.ticker, c.name, c.sector, COUNT(d.id) AS documents,
               ROUND(AVG(d.sentiment), 3) AS sentiment,
               MAX(d.published_at) AS latest
        FROM companies c LEFT JOIN documents d ON d.company_id = c.id
        GROUP BY c.id ORDER BY documents DESC, c.ticker
      SQL
      recent: rows(<<~SQL).map { |r| r.merge(published_at: to_date(r[:published_at])) },
        SELECT d.id, d.title, d.doc_type, d.published_at, d.sentiment, c.ticker
        FROM documents d LEFT JOIN companies c ON c.id = d.company_id
        ORDER BY d.published_at DESC, d.id DESC LIMIT 8
      SQL
      sentiment: {
        # No documents means no tone, not a neutral 0.0.
        mean: mean.nil? ? nil : mean.to_f.round(3),
        distribution: rows(<<~SQL)
          SELECT CASE WHEN sentiment >= 0.18 THEN 'positive'
                      WHEN sentiment <= -0.18 THEN 'negative'
                      ELSE 'neutral' END AS value,
                 COUNT(*) AS count
          FROM documents GROUP BY 1 ORDER BY 1
        SQL
      },
      trending: trending_themes(window_days: 180)[:themes].first(8)
    }
  end

  # Mean document sentiment by month, with volume, for a diverging bar chart.
  def sentiment_timeline(ticker: nil, months: 24)
    cutoff = months_cutoff(months)
    return [] unless cutoff

    where, binds = window_where(cutoff, ticker)
    rows(<<~SQL, *binds)
      SELECT substr(d.published_at, 1, 7) AS month,
             ROUND(AVG(d.sentiment), 4) AS sentiment,
             COUNT(*) AS documents
      FROM documents d LEFT JOIN companies c ON c.id = d.company_id
      WHERE #{where}
      GROUP BY month ORDER BY month
    SQL
  end

  # Document counts per month per doc_type, aligned to one month axis so a
  # stacked bar chart can take the series as they are.
  def volume_by_type(ticker: nil, months: 24)
    cutoff = months_cutoff(months)
    return { months: [], series: [] } unless cutoff

    where, binds = window_where(cutoff, ticker)
    found = rows(<<~SQL, *binds)
      SELECT substr(d.published_at, 1, 7) AS month, d.doc_type, COUNT(*) AS count
      FROM documents d LEFT JOIN companies c ON c.id = d.company_id
      WHERE #{where}
      GROUP BY month, d.doc_type ORDER BY month
    SQL
    months_seen = found.map { |r| r[:month] }.uniq.sort
    types = found.map { |r| r[:doc_type] }.uniq.sort
    index = found.to_h { |r| [[r[:month], r[:doc_type]], r[:count]] }
    {
      months: months_seen,
      series: types.map do |doc_type|
        { name: doc_type, values: months_seen.map { |m| index.fetch([m, doc_type], 0) } }
      end
    }
  end

  # Themes over-represented in the trailing window versus the period before it.
  def trending_themes(window_days: 120, ticker: nil, limit: 12)
    as_of = latest_corpus_date
    unless as_of
      return { as_of: nil, window_days: window_days, recent_documents: 0,
               baseline_documents: 0, themes: [] }
    end

    recent_cutoff = as_of - window_days
    base_cutoff = as_of - (window_days * 3)
    recent = document_texts(from: recent_cutoff, ticker: ticker)
    baseline = document_texts(from: base_cutoff, before: recent_cutoff, ticker: ticker)

    # For one company, its own name is in every document it publishes; it ranks
    # only because the baseline window held fewer documents ("novagrid
    # systems" on the demo corpus). It is identity, not a theme.
    name_words = ticker.present? ? Nlp.tokenize(Company.find_ticker(ticker)&.name.to_s).to_set : Set.new
    themes = Nlp.theme_trends(recent, baseline, limit: THEME_CANDIDATES)
                .reject { |row| boilerplate_theme?(row[:theme]) }
                .reject { |row| name_words.any? && row[:theme].split(" ").to_set <= name_words }
                .first(limit)
    {
      as_of: as_of,
      window_days: window_days,
      recent_documents: recent.size,
      baseline_documents: baseline.size,
      themes: themes
    }
  end

  # True when any word of a theme is filing boilerplate or not a word at all
  # ("n/a", "and/or": the tokenizer keeps slashes inside a token).
  def boilerplate_theme?(theme)
    theme.to_s.split(" ").any? { |token| THEME_STOPLIST.include?(token) || token.include?("/") }
  end

  # Everything known about one company, research and financials together.
  def company_profile(ticker)
    company = Company.find_ticker(ticker)
    return nil unless company

    sentiment = Document.where(company_id: company.id).average(:sentiment)
    sentiment = sentiment&.to_f&.round(3)
    company.attributes.symbolize_keys.merge(
      # FY before LTM within a fiscal year: the LTM row extends that year.
      financials: company.financials.order(:fiscal_year, :period_type).map { |f| f.attributes.symbolize_keys },
      market_data: company.market_datum&.attributes&.symbolize_keys || {},
      document_count: Document.where(company_id: company.id).count,
      # A company with no documents has no tone: nil (n/a), not neutral.
      sentiment: sentiment,
      sentiment_label: sentiment.nil? ? nil : Nlp.sentiment_label(sentiment),
      documents: Document.where(company_id: company.id).newest_first.limit(25)
                         .pluck(:id, :title, :doc_type, :source, :published_at, :sentiment)
                         .map { |id, title, doc_type, source, published_at, sent|
                           { id: id, title: title, doc_type: doc_type, source: source,
                             published_at: published_at, sentiment: sent }
                         },
      kpis: kpi_series(ticker),
      sentiment_timeline: sentiment_timeline(ticker: ticker),
      themes: trending_themes(ticker: ticker, limit: 8)[:themes],
      metrics: valuation_snapshot(ticker)
    )
  end

  # Extracted KPIs for a company, newest company-level value per metric plus history.
  #
  # The reference took the newest point whatever it was. On real filings that is
  # often a segment column or a row of a flattened table, so a tile read "Gross
  # margin 29.9%" for a company whose headline margin was 41.4%. The latest value
  # now comes from the newest sentence that is neither; only when every sentence
  # for a metric is segment- or table-level is the newest one used, and then the
  # bucket says so (segment_or_table: true) so a view does not present it as a
  # company-level figure.
  def kpi_series(ticker)
    found = Kpi.joins(:document).joins(:company)
               .where(companies: { ticker: ticker.to_s.upcase })
               .order("kpis.metric", "documents.published_at", "kpis.id")
               .pluck("kpis.metric", "kpis.value", "kpis.unit", "kpis.period", "kpis.context",
                      "kpis.document_id", "documents.published_at", "documents.title")
    grouped = {}
    found.each do |metric, value, unit, period, context, document_id, published_at, title|
      bucket = grouped[metric] ||= {
        metric: metric,
        label: KPI_LABELS.fetch(metric) { metric.split("_").map(&:capitalize).join(" ") },
        unit: unit,
        points: []
      }
      bucket[:points] << {
        period: period, published_at: published_at, value: value, document_id: document_id,
        title: title, context: context,
        segment_or_table: segment_or_table?(context), measure: measure(context)
      }
    end

    grouped.each_value do |bucket|
      # Stable by publication date (the SQL already orders it; keep the id order on ties).
      bucket[:points] = bucket[:points].each_with_index.sort_by { |p, i| [p[:published_at].to_s, i] }.map(&:first)
      company_level = bucket[:points].reject { |p| p[:segment_or_table] }
      chosen = (company_level.presence || bucket[:points]).last
      bucket[:latest] = chosen&.dig(:value)
      bucket[:period] = chosen&.dig(:published_at)
      bucket[:latest_context] = chosen&.dig(:context)
      bucket[:latest_document_id] = chosen&.dig(:document_id)
      bucket[:segment_or_table] = chosen ? chosen[:segment_or_table] : false
      bucket[:measure] = chosen&.dig(:measure)
      bucket[:observations] = bucket[:points].size
    end
    grouped.values.sort_by { |b| [-b[:observations], b[:metric]] }
  end

  # True when a KPI's sentence is a flattened table row or names a segment.
  def segment_or_table?(context)
    text = context.to_s
    return false if text.strip.empty?

    Nlp.looks_like_table_row(text) || text.match?(SEGMENT_RE)
  end

  # "adjusted" / "GAAP" when the sentence says which measure it quotes, else nil.
  def measure(context)
    text = context.to_s
    return "adjusted" if text.match?(ADJUSTED_RE)
    return "GAAP" if text.match?(GAAP_RE)

    nil
  end

  # Market multiples for one company (Valuation picks the LTM or last-FY basis).
  def valuation_snapshot(ticker)
    Valuation.company_metrics(ticker) || {}
  end

  # Re-run every saved search and report documents newer than last seen.
  #
  # This is the "alert" half of a research platform: a saved search is only
  # useful if it tells you what arrived since you last looked.
  #
  # new_documents is the true count of matching documents above the saved
  # search's watermark (Search's document-level total_documents). The reference
  # reported len(hits), which capped every alert at its page size of 10.
  def check_alerts(mark_seen: false)
    alerts = []
    SavedSearch.order(:id).each do |saved|
      watermark = saved.last_seen_document_id || 0
      # Taken before the search so a document ingested mid-check is not marked
      # seen without having been counted.
      corpus_max = Document.maximum(:id) || 0
      filters = saved.filters_hash.merge(min_document_id: watermark)
      result = Search.search(saved.query, filters, limit: 10, summarize: false)
      hits = result[:results] || []
      total = result[:total_documents] || hits.size
      alerts << {
        saved_search_id: saved.id,
        name: saved.name,
        query: saved.query,
        new_documents: total,
        hits: hits
      }
      next unless mark_seen && total.positive?

      # Hits are ranked by relevance and only the first page is returned, so the
      # newest hit is not the newest match. Every matching document is at or
      # below the corpus maximum taken before the search, so that is the
      # watermark that leaves nothing reported twice and nothing skipped.
      newest = [corpus_max, *hits.map { |h| h[:document_id].to_i }].max
      saved.update_column(:last_seen_document_id, newest)
    end
    alerts
  end

  # --- helpers -------------------------------------------------------------

  def latest_corpus_date
    to_date(Document.maximum(:published_at))
  end

  def months_cutoff(months)
    as_of = latest_corpus_date
    as_of && (as_of - (months * DAYS_PER_MONTH).to_i)
  end

  def window_where(cutoff, ticker)
    where = +"d.published_at >= ?"
    binds = [cutoff]
    if ticker.present?
      where << " AND c.ticker = ?"
      binds << ticker.to_s.upcase
    end
    [where, binds]
  end

  # One string per document, from its chunks in order.
  #
  # Chunk text rather than the raw body: chunks have speaker attribution split
  # off, so "Dana Okafor, Chief Financial Officer:" cannot surface as a theme.
  def document_texts(from:, before: nil, ticker: nil)
    where, binds = window_where(from, ticker)
    if before
      where << " AND d.published_at < ?"
      binds << before
    end
    texts = {}
    rows(<<~SQL, *binds).each { |r| (texts[r[:document_id]] ||= []) << r[:text] }
      SELECT ch.document_id, ch.text
      FROM chunks ch JOIN documents d ON d.id = ch.document_id
      LEFT JOIN companies c ON c.id = d.company_id
      WHERE #{where}
      ORDER BY ch.document_id, ch.seq
    SQL
    texts.values.map { |parts| parts.compact.join(" ") }.reject { |t| t.strip.empty? }
  end

  def rows(sql, *binds)
    statement = binds.empty? ? sql : ActiveRecord::Base.sanitize_sql_array([sql, *binds])
    ActiveRecord::Base.connection.select_all(statement).to_a.map(&:symbolize_keys)
  end

  def to_date(value)
    return nil if value.nil?
    return value if value.is_a?(Date)

    Date.iso8601(value.to_s[0, 10])
  rescue ArgumentError
    nil
  end

  private_class_method :latest_corpus_date, :months_cutoff, :window_where, :document_texts,
                       :rows, :to_date
end
