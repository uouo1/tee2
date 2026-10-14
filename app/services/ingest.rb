# frozen_string_literal: true

require "csv"
require "json"
require "pathname"

# Corpus ingestion: documents in, searchable + scored chunks out.
#
# Accepts a hash per document (from JSON/JSONL/CSV, the API, the SEC loader or
# the demo seeder), splits it into retrieval-sized chunks, scores sentiment per
# chunk, extracts KPIs and writes everything in one transaction so the FTS index
# (kept in step by the chunks_ai/ad/au triggers, see SearchIndex) can never
# drift from the documents table.
#
# Port of argos/ingest.py. Regex translation notes: Python's \w and \s are
# Unicode-aware and its ^/$ anchor the whole string, so the Ruby patterns use
# [[:word:]] / [[:space:]] and \A / \z; `re.S` becomes the /m flag.
module Ingest
  DOC_TYPES = %w[
    transcript
    filing
    research
    news
    press-release
    expert-call
    investor-day
    memo
  ].freeze

  # "Jane Doe, CEO: ..." — one to four capitalised name words, an optional
  # ", role" of 3–40 characters, then the colon. Digits inside a name word are
  # fine ("A.J. O'Neil-Smith"), a word starting with a digit ("Q3 2026 Results:")
  # is not a speaker.
  SPEAKER_RE = /\A(?<speaker>[A-Z][[[:word:]].'-]*(?: [A-Z][[[:word:]].'-]*){0,3}(?:, [^:]{3,40})?):[[:space:]]*(?<body>.+)\z/m
  MIN_CHUNK_CHARS = 180
  MAX_CHUNK_CHARS = 1400

  # A paragraph break is a blank line (possibly containing whitespace).
  PARAGRAPH_RE = /\n[[:space:]]*\n+/
  # Python's str.strip(): any Unicode whitespace at both ends.
  EDGE_WS_RE = /\A[[:space:]]+|[[:space:]]+\z/

  CORPUS_SUFFIXES = %w[.json .jsonl .csv .txt .md].freeze
  # Reference data (companies, precedent transactions) lives beside the corpus
  # files but is loaded by the seeder / Sources::Sec, never as documents.
  REFERENCE_PREFIXES = %w[companies transactions].freeze
  REQUIRED_FIELDS = %i[title doc_type published_at body].freeze

  module_function

  def split_paragraphs(body)
    parts = (body || "").split(PARAGRAPH_RE).map { |p| strip_ws(p) }.reject(&:empty?)
    return parts unless parts.empty?

    stripped = strip_ws(body || "")
    stripped.empty? ? [] : [stripped]
  end

  # Paragraph-aware chunking with speaker attribution for transcripts.
  #
  # Short paragraphs are glued to their neighbour (an "Operator: next question"
  # line is noise on its own) and very long ones are split on sentence
  # boundaries so a snippet always has usable context.
  def chunk_body(body)
    chunks = []
    pending = nil

    flush = lambda do
      chunks << pending if pending && !strip_ws(pending[:text]).empty?
      pending = nil
    end

    split_paragraphs(body).each do |para|
      match = SPEAKER_RE.match(para)
      speaker = match ? strip_ws(match[:speaker]) : nil
      text = match ? strip_ws(match[:body]) : para

      if text.length > MAX_CHUNK_CHARS
        flush.call
        buffer = ""
        pieces = Nlp.sentences(text)
        pieces = [text] if pieces.empty?
        pieces.each do |sentence|
          if !buffer.empty? && buffer.length + sentence.length > MAX_CHUNK_CHARS
            chunks << { speaker: speaker, text: strip_ws(buffer) }
            buffer = ""
          end
          buffer = strip_ws("#{buffer} #{sentence}")
        end
        chunks << { speaker: speaker, text: strip_ws(buffer) } unless buffer.empty?
        next
      end

      # Glue a short paragraph onto the next one only when the speaker is the
      # same: a speaker change always starts a new chunk, however short.
      if pending && pending[:text].length < MIN_CHUNK_CHARS && pending[:speaker] == speaker
        pending[:text] = strip_ws("#{pending[:text]} #{text}")
        next
      end
      flush.call
      pending = { speaker: speaker, text: text }
    end
    flush.call
    chunks
  end

  # Insert one document plus its chunks and KPIs. Returns the Document.
  #
  # Returns nil when `external_id` already exists, which makes repeated ingest
  # runs idempotent instead of duplicating a corpus. Keys may be symbols or
  # strings (JSON API payloads arrive with strings); unknown keys are ignored.
  # Runs in a transaction, which joins the caller's when there is one, so
  # `ingest_many` really is all-or-nothing.
  def ingest_document(attrs)
    doc = attrs.to_h.transform_keys(&:to_sym)
    missing = REQUIRED_FIELDS.select { |key| doc[key].blank? }
    raise ArgumentError, "document missing required field(s): #{missing.join(', ')}" if missing.any?

    # A blank external_id is "no id", not an id that every untagged document shares.
    external_id = doc[:external_id].presence
    return nil if external_id && Document.exists?(external_id: external_id)

    published_at = coerce_date(doc[:published_at])
    body = doc[:body]

    ActiveRecord::Base.transaction do
      company_id = doc[:company_id].presence
      if company_id.nil? && doc[:ticker].present?
        ticker = doc[:ticker].to_s.upcase
        company = Company.find_ticker(ticker)
        if company
          company_id = company.id
        elsif doc[:company_name].present?
          # The ticker is new to us; a name is enough to register the company so
          # the document (and its KPIs) are attributed from day one.
          company_id = Company.upsert_by_ticker!(ticker: ticker, name: doc[:company_name]).id
        end
      end

      document = Document.create!(
        external_id: external_id,
        title: doc[:title],
        company_id: company_id,
        doc_type: doc[:doc_type],
        source: doc[:source],
        author: doc[:author],
        published_at: published_at,
        language: doc.fetch(:language, "en"),
        url: doc[:url],
        sentiment: Nlp.score_sentiment(body).round(4),
        word_count: Nlp.tokenize(body).size,
        body: body
      )

      # KPIs without an explicit period are dated to the publication month.
      period = doc[:period].presence || published_at.strftime("%Y-%m")
      chunk_body(body).each_with_index do |chunk, seq|
        record = document.chunks.create!(
          seq: seq,
          speaker: chunk[:speaker],
          text: chunk[:text],
          sentiment: Nlp.score_sentiment(chunk[:text]).round(4)
        )
        Nlp.extract_kpis(chunk[:text]).each do |kpi|
          document.kpis.create!(
            chunk: record,
            company_id: company_id,
            metric: kpi[:metric],
            value: kpi[:value],
            unit: kpi[:unit],
            period: period,
            context: kpi[:context][0, 600]
          )
        end
      end

      document
    end
  end

  # Ingest every document in `docs` (any Enumerable, lazy ones included) inside
  # one transaction: a bad row rolls back the good ones instead of leaving a
  # half-loaded corpus behind.
  def ingest_many(docs)
    added = skipped = 0
    ActiveRecord::Base.transaction do
      docs.each do |doc|
        if ingest_document(doc).nil?
          skipped += 1
        else
          added += 1
        end
      end
    end
    { added: added, skipped: skipped }
  end

  # Read documents from .json (list or {documents: [...]}), .jsonl, .csv or .txt/.md.
  #
  # Returns a lazy Enumerator (the Python version is a generator), so an
  # unsupported file type is only reported when the result is iterated.
  def read_documents(path)
    path = Pathname(path)
    Enumerator.new do |yielder|
      case path.extname.downcase
      when ".jsonl"
        File.foreach(path, encoding: "UTF-8", universal_newline: true) do |line|
          line = strip_ws(line)
          yielder << JSON.parse(line, symbolize_names: true) unless line.empty?
        end
      when ".json"
        payload = JSON.parse(File.read(path, encoding: "UTF-8", universal_newline: true), symbolize_names: true)
        rows = payload.is_a?(Hash) ? payload.fetch(:documents, []) : payload
        rows.each { |row| yielder << row }
      when ".csv"
        # csv.DictReader semantics: header row as keys, blank lines skipped,
        # missing cells nil. Cells beyond the header (keyed nil by Ruby's CSV)
        # are dropped rather than turned into a nil symbol.
        CSV.foreach(path, headers: true, skip_blanks: true, encoding: "UTF-8") do |row|
          yielder << row.to_h.reject { |key, _| key.nil? }.transform_keys(&:to_sym)
        end
      when ".txt", ".md"
        # universal_newline mirrors Python's text-mode read: \r\n becomes \n.
        yielder << {
          title: title_case(path.basename(path.extname).to_s.tr("_", " ")),
          doc_type: "memo",
          published_at: "1970-01-01",
          source: path.basename.to_s,
          body: File.read(path, encoding: "UTF-8", universal_newline: true)
        }
      else
        raise ArgumentError, "unsupported corpus file type: #{path.basename}"
      end
    end
  end

  # Ingest a single corpus file or every corpus file in a directory.
  def ingest_path(path)
    path = Pathname(path)
    # Python's sorted(rglob("*")) orders by path components (dotfiles included),
    # so "a/z.json" sorts before "a-b.json"; sort_by the component array to match.
    paths = path.directory? ? path.find.select(&:file?).sort_by { |p| p.each_filename.to_a } : [path]
    totals = { added: 0, skipped: 0, files: 0 }
    paths.each do |candidate|
      next unless CORPUS_SUFFIXES.include?(candidate.extname.downcase)
      next if candidate.basename.to_s.start_with?(*REFERENCE_PREFIXES) # reference data, loaded by the seeder

      result = ingest_many(read_documents(candidate))
      totals[:added] += result[:added]
      totals[:skipped] += result[:skipped]
      totals[:files] += 1
    end
    totals
  end

  # Python stored str(published_at)[:10] verbatim; the Rails column is a real
  # date, so the same ten characters are parsed strictly and anything that is
  # not an ISO day is rejected up front instead of becoming a nil date.
  def coerce_date(value)
    return value.to_date if value.is_a?(Date) || value.is_a?(Time)

    Date.strptime(value.to_s[0, 10], "%Y-%m-%d")
  rescue Date::Error
    raise ArgumentError, "document published_at must be an ISO date (YYYY-MM-DD), got #{value.inspect}"
  end

  # Python's str.title(): a cased letter is upcased after an uncased character
  # (space, digit, punctuation) and downcased after another letter, so
  # "q3_call-notes.v2" -> "Q3 Call-Notes.V2" once underscores are spaces.
  def title_case(text)
    prev_cased = false
    text.each_char.map do |char|
      cased = char.match?(/[\p{Lu}\p{Ll}\p{Lt}]/)
      out = if !cased then char
            elsif prev_cased then char.downcase
            else char.upcase
            end
      prev_cased = cased
      out
    end.join
  end

  # Python's str.strip(): Unicode whitespace at both ends.
  def strip_ws(text)
    text.gsub(EDGE_WS_RE, "")
  end

  private_class_method :coerce_date, :title_case, :strip_ws
end
