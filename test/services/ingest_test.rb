# frozen_string_literal: true

require "test_helper"
require "tmpdir"

# Port of tests/test_ingest.py, plus coverage for what the contract adds
# (constants, split_paragraphs, read_documents per file type, the one-transaction
# guarantee of ingest_many, company resolution rules, KPI period/context).
# Expected numbers were taken from the Python reference implementation.

module IngestTestHelpers
  SAMPLE_DOC = {
    external_id: "doc-1",
    title: "Q3 call",
    doc_type: "transcript",
    published_at: "2026-08-01",
    ticker: "NVG",
    company_name: "NovaGrid",
    body: "Jane Doe, CEO: Revenue grew 12.5% and gross margin reached 68.0%."
  }.freeze

  def fts_rowids(term)
    ActiveRecord::Base.connection.select_values(
      "SELECT rowid FROM chunks_fts WHERE chunks_fts MATCH #{ActiveRecord::Base.connection.quote(term)}"
    )
  end

  # Transactional tests roll back, but the on-disk test database survives a run
  # that was killed half-way, and the FTS assertions below are absolute, so
  # every database test starts from an empty corpus.
  def purge!
    Document.destroy_all
    Company.destroy_all
  end

  def with_corpus_dir
    Dir.mktmpdir("ingest", Rails.root.join("tmp").to_s) { |dir| yield Pathname(dir) }
  end

  def write_json(path, payload)
    File.write(path, JSON.generate(payload), encoding: "utf-8")
  end
end

class IngestChunkingTest < ActiveSupport::TestCase
  test "speaker attribution" do
    body = "Operator: Good morning.\n\n" \
           "Jane Doe, CEO: Revenue grew 18.4% this quarter and momentum is strong.\n\n" \
           "John Roe, CFO: We see headwinds in EMEA and expect slower bookings."
    chunks = Ingest.chunk_body(body)
    assert_equal ["Operator", "Jane Doe, CEO", "John Roe, CFO"], chunks.map { |c| c[:speaker] }
    refute_includes chunks[1][:text], "Jane Doe"
    assert_equal "Revenue grew 18.4% this quarter and momentum is strong.", chunks[1][:text]
  end

  test "long paragraph is split" do
    body = (["This is a sentence about grid software."] * 120).join(" ")
    chunks = Ingest.chunk_body(body)
    assert_operator chunks.size, :>, 1
    assert chunks.all? { |c| c[:text].length <= Ingest::MAX_CHUNK_CHARS + 200 }
  end

  test "empty body" do
    assert_equal [], Ingest.chunk_body("")
    assert_equal [], Ingest.chunk_body(nil)
  end

  test "constants match the contract" do
    assert_equal %w[transcript filing research news press-release expert-call investor-day memo], Ingest::DOC_TYPES
    assert Ingest::DOC_TYPES.frozen?
    assert_equal 180, Ingest::MIN_CHUNK_CHARS
    assert_equal 1400, Ingest::MAX_CHUNK_CHARS
  end

  test "split_paragraphs splits on blank lines, strips and drops empties" do
    assert_equal %w[a b c], Ingest.split_paragraphs("  a\n\n\n  b \n \n c  ")
    assert_equal ["One para only."], Ingest.split_paragraphs("One para only.")
    # a single newline is a line break inside a paragraph, not a paragraph break
    assert_equal ["First line.\nSecond line."], Ingest.split_paragraphs("First line.\nSecond line.")
    assert_equal [], Ingest.split_paragraphs("   ")
    assert_equal [], Ingest.split_paragraphs("")
    assert_equal [], Ingest.split_paragraphs(nil)
  end

  test "chunks are symbol-keyed hashes" do
    chunk = Ingest.chunk_body("One para only.").first
    assert_equal [:speaker, :text], chunk.keys
    assert_nil chunk[:speaker]
    assert_equal "One para only.", chunk[:text]
  end

  test "short paragraphs are glued to a neighbour with the same speaker only" do
    body = "Short one.\n\nAnother short one.\n\nOperator: Thanks.\n\nOperator: Next question."
    assert_equal [{ speaker: nil, text: "Short one. Another short one." },
                  { speaker: "Operator", text: "Thanks. Next question." }], Ingest.chunk_body(body)
    # a speaker change always starts a new chunk, however short the previous one
    assert_equal [{ speaker: "Operator", text: "Thanks." },
                  { speaker: "Jane Doe, CEO", text: "Hi." }], Ingest.chunk_body("Operator: Thanks.\n\nJane Doe, CEO: Hi.")
  end

  test "speaker regex reference cases" do
    cases = {
      "Operator: Good morning." => ["Operator", "Good morning."],
      "Jane Doe, CEO: Revenue grew." => ["Jane Doe, CEO", "Revenue grew."],
      "Note: this is important" => ["Note", "this is important"],
      "Q3 2026 Results: Revenue grew" => nil,                     # a digit word breaks the name
      "Mary Ann Van Der Berg: five words" => nil,                 # at most four name words
      "Mary Ann Van Der: four words" => ["Mary Ann Van Der", "four words"],
      "José Núñez, CFO: Unicode name" => ["José Núñez, CFO", "Unicode name"],  # \w is Unicode in Python
      "Jane Doe, CEO: First line.\nSecond line." => ["Jane Doe, CEO", "First line.\nSecond line."],
      "https://example.com: nope" => nil,
      "John Roe, Chief Financial Officer and Treasurer of the Company Inc: too long?" => nil,
      "A.J. O'Neil-Smith: initials and punctuation" => ["A.J. O'Neil-Smith", "initials and punctuation"],
      "Analyst, Big Bank: short role" => ["Analyst, Big Bank", "short role"],
      "Jane Doe, CE: role too short" => nil,
      "Operator:Good morning no space" => ["Operator", "Good morning no space"]
    }
    cases.each do |para, expected|
      match = Ingest::SPEAKER_RE.match(para)
      if expected.nil?
        assert_nil match, para
      else
        assert_equal expected, [match[:speaker], match[:body]], para
      end
    end
  end

  test "speaker is kept across a multi-line paragraph" do
    assert_equal [{ speaker: "Jane Doe, CEO", text: "First line.\nSecond line." }],
                 Ingest.chunk_body("Jane Doe, CEO: First line.\nSecond line.")
  end

  test "long paragraph split lengths match the reference" do
    body = (["This is a sentence about grid software."] * 120).join(" ")
    assert_equal [1399, 1399, 1399, 599], Ingest.chunk_body(body).map { |c| c[:text].length }
  end

  test "a long speaker paragraph keeps its speaker on every piece" do
    body = "Jane Doe, CEO: " + (["Margins expanded again this quarter."] * 60).join(" ")
    chunks = Ingest.chunk_body(body)
    assert_equal [1368, 850], chunks.map { |c| c[:text].length }
    assert_equal ["Jane Doe, CEO"], chunks.map { |c| c[:speaker] }.uniq
  end

  test "a long paragraph without sentence boundaries becomes one oversized chunk" do
    body = "word " * 400 # 2000 chars, no terminal punctuation -> Nlp.sentences returns it whole
    chunks = Ingest.chunk_body(body)
    assert_equal 1, chunks.size
    assert_equal body.strip, chunks.first[:text]
  end
end

class IngestDocumentTest < ActiveSupport::TestCase
  include IngestTestHelpers

  setup do
    purge!
    @doc = SAMPLE_DOC.dup
  end

  test "creates document chunks and kpis" do
    document = Ingest.ingest_document(@doc)
    assert_kind_of Document, document
    assert document.persisted?
    assert_equal 1, Chunk.count
    assert_equal %w[gross_margin revenue_growth], Kpi.pluck(:metric).sort
  end

  test "company is resolved from ticker" do
    document = Ingest.ingest_document(@doc)
    assert_equal "NVG", document.company.ticker
    assert_equal "NovaGrid", document.company.name
    assert_equal 1, Company.count
  end

  test "external_id makes ingest idempotent" do
    Ingest.ingest_document(@doc)
    assert_nil Ingest.ingest_document(@doc)
    assert_equal 1, Document.count
  end

  test "missing fields raise" do
    error = assert_raises(ArgumentError) { Ingest.ingest_document({ title: "No body" }) }
    assert_equal "document missing required field(s): doc_type, published_at, body", error.message
    assert_raises(ArgumentError) { Ingest.ingest_document(@doc.merge(body: "")) }
    assert_equal 0, Document.count
  end

  test "fts index is populated by the insert trigger" do
    document = Ingest.ingest_document(@doc)
    assert_equal [document.chunks.first.id], fts_rowids("margin")
    assert_equal 1, ActiveRecord::Base.connection.select_value("SELECT COUNT(*) FROM chunks_fts WHERE chunks_fts MATCH 'margin'")
  end

  test "deleting a document clears the index" do
    document = Ingest.ingest_document(@doc)
    assert_equal 1, fts_rowids("margin").size
    document.destroy
    assert_equal [], fts_rowids("margin")
    assert_equal 0, Chunk.count
    assert_equal 0, Kpi.count
  end

  test "document sentiment is rounded to four places and words are counted" do
    document = Ingest.ingest_document(@doc)
    assert_equal 0.2457, document.sentiment
    assert_equal 11, document.word_count
    assert_equal @doc[:body], document.body
    assert_equal Date.new(2026, 8, 1), document.published_at
    assert_equal "en", document.language
    assert_equal "doc-1", document.external_id
  end

  test "chunk sentiment is written per chunk" do
    body = "Operator: Good morning.\n\n" \
           "Jane Doe, CEO: Revenue grew 18.4% this quarter and momentum is strong.\n\n" \
           "John Roe, CFO: We see headwinds in EMEA and expect slower bookings."
    document = Ingest.ingest_document(@doc.merge(body: body))
    assert_equal 0.1711, document.sentiment
    assert_equal 27, document.word_count
    chunks = document.chunks.to_a
    assert_equal [0, 1, 2], chunks.map(&:seq)
    assert_equal ["Operator", "Jane Doe, CEO", "John Roe, CFO"], chunks.map(&:speaker)
    assert_equal [0.0, 0.8889, -0.5926], chunks.map(&:sentiment)
  end

  test "published_at accepts timestamps and dates; kpi period defaults to the month" do
    document = Ingest.ingest_document(@doc.merge(published_at: "2026-08-01T10:00:00"))
    assert_equal Date.new(2026, 8, 1), document.published_at
    assert_equal ["2026-08"], document.kpis.pluck(:period).uniq

    other = Ingest.ingest_document(@doc.merge(external_id: "doc-2", published_at: Date.new(2026, 9, 3)))
    assert_equal Date.new(2026, 9, 3), other.published_at
    assert_equal ["2026-09"], other.kpis.pluck(:period).uniq

    error = assert_raises(ArgumentError) { Ingest.ingest_document(@doc.merge(external_id: "doc-3", published_at: "yesterday")) }
    assert_match(/ISO date/, error.message)
  end

  test "explicit period wins for kpis" do
    document = Ingest.ingest_document(@doc.merge(period: "FY2026"))
    assert_equal ["FY2026"], document.kpis.pluck(:period).uniq
  end

  test "kpi rows link chunk and company and truncate context to 600 characters" do
    long_sentence = "Gross margin reached 68.0% " + ("as pricing held and " * 40) + "demand stayed firm"
    assert_equal 845, long_sentence.length
    document = Ingest.ingest_document(@doc.merge(body: long_sentence))
    kpi = document.kpis.sole
    assert_equal "gross_margin", kpi.metric
    assert_equal 68.0, kpi.value
    assert_equal "%", kpi.unit
    assert_equal document.chunks.first.id, kpi.chunk_id
    assert_equal document.company_id, kpi.company_id
    assert_equal 600, kpi.context.length
    assert kpi.context.start_with?("Gross margin reached 68.0% as ")
  end

  test "ticker without company_name does not create a company" do
    document = Ingest.ingest_document(@doc.except(:company_name))
    assert_nil document.company_id
    assert_equal 0, Company.count
    assert_nil document.kpis.first.company_id
  end

  test "ticker lookup is case-insensitive and never renames an existing company" do
    Company.create!(ticker: "NVG", name: "NovaGrid")
    document = Ingest.ingest_document(@doc.merge(ticker: "nvg", company_name: "Renamed Co"))
    assert_equal "NovaGrid", document.company.name
    assert_equal 1, Company.count
  end

  test "an explicit company_id is used as given" do
    company = Company.create!(ticker: "OTH", name: "Other")
    document = Ingest.ingest_document(@doc.merge(company_id: company.id))
    assert_equal company.id, document.company_id
    assert_equal 1, Company.count # the NVG ticker is ignored
  end

  test "language defaults to en and an explicit nil is stored" do
    assert_equal "en", Ingest.ingest_document(@doc).language
    assert_nil Ingest.ingest_document(@doc.merge(external_id: "doc-2", language: nil)).language
    assert_equal "de", Ingest.ingest_document(@doc.merge(external_id: "doc-3", language: "de")).language
  end

  test "optional metadata is stored" do
    document = Ingest.ingest_document(@doc.merge(source: "Transcript Co", author: "J. Doe", url: "https://example.com/q3"))
    assert_equal "Transcript Co", document.source
    assert_equal "J. Doe", document.author
    assert_equal "https://example.com/q3", document.url
  end

  test "blank external_id is treated as absent" do
    first = Ingest.ingest_document(@doc.merge(external_id: ""))
    second = Ingest.ingest_document(@doc.merge(external_id: nil))
    assert_nil first.external_id
    assert_nil second.external_id
    assert_equal 2, Document.count
  end

  test "string keys and unknown keys are accepted" do
    attrs = @doc.transform_keys(&:to_s).merge("extra" => "ignored")
    document = Ingest.ingest_document(attrs)
    assert_equal "Q3 call", document.title
    assert_equal "NVG", document.company.ticker
    assert_nil Ingest.ingest_document(attrs)
  end

  test "a document the database rejects leaves nothing behind" do
    # A dangling company_id trips the foreign key (Python: sqlite3.IntegrityError),
    # the earliest point the pipeline can fail once the field check has passed.
    assert_raises(ActiveRecord::InvalidForeignKey) do
      Ingest.ingest_document(@doc.merge(company_id: 999_999))
    end
    assert_equal 0, Document.count
    assert_equal 0, Chunk.count
    assert_equal [], fts_rowids("margin")
  end

  test "a blank company_id, as an empty CSV cell gives, falls back to ticker resolution" do
    document = Ingest.ingest_document(@doc.merge(company_id: ""))
    assert_equal "NVG", document.company.ticker
    assert_equal document.company_id, document.kpis.first.company_id
  end
end

class IngestManyTest < ActiveSupport::TestCase
  include IngestTestHelpers

  # The one-transaction guarantee can only be observed against the real
  # database, outside the per-test transaction Rails normally wraps around a
  # test, so this class cleans up after itself instead.
  self.use_transactional_tests = false

  setup { purge! }
  teardown { purge! }

  test "counts added and skipped" do
    a = SAMPLE_DOC.merge(external_id: "a1")
    b = SAMPLE_DOC.merge(external_id: "b1", title: "B")
    assert_equal({ added: 2, skipped: 1 }, Ingest.ingest_many([a, b, a]))
    assert_equal 2, Document.count
    assert_equal({ added: 0, skipped: 2 }, Ingest.ingest_many([a, b]))
  end

  test "accepts any enumerable, including a lazy enumerator" do
    docs = Enumerator.new { |y| y << SAMPLE_DOC.merge(external_id: "e1") }
    assert_equal({ added: 1, skipped: 0 }, Ingest.ingest_many(docs))
    assert_equal({ added: 0, skipped: 0 }, Ingest.ingest_many([]))
  end

  test "runs in one transaction so a bad row rolls back the good ones" do
    good = SAMPLE_DOC.merge(external_id: "g1")
    bad = { title: "No body" }
    assert_raises(ArgumentError) { Ingest.ingest_many([good, bad]) }
    assert_equal 0, Document.count
    assert_equal 0, Chunk.count
    assert_equal 0, Company.count
    assert_equal [], fts_rowids("margin")
  end
end

class IngestFilesTest < ActiveSupport::TestCase
  include IngestTestHelpers

  setup { purge! }

  test "reads json jsonl and directory" do
    result = with_corpus_dir do |root|
      write_json(root.join("a.json"), [{
        external_id: "a1", title: "A", doc_type: "news", published_at: "2026-01-01", body: "Margins expanded."
      }])
      File.write(root.join("b.jsonl"), JSON.generate({
        external_id: "b1", title: "B", doc_type: "news", published_at: "2026-01-02", body: "Guidance was raised."
      }) + "\n", encoding: "utf-8")
      Ingest.ingest_path(root)
    end
    assert_equal 2, result[:added]
    assert_equal 2, result[:files]
    assert_equal({ added: 2, skipped: 0, files: 2 }, result)
    assert_equal %w[A B], Document.order(:id).pluck(:title)
  end

  test "read_documents handles json lists and documents envelopes" do
    with_corpus_dir do |root|
      write_json(root.join("list.json"), [{ external_id: "l1", title: "L", doc_type: "news", published_at: "2026-01-01", body: "x" }])
      write_json(root.join("envelope.json"), { documents: [{ external_id: "e1", title: "E" }] })
      write_json(root.join("empty.json"), { other: 1 })
      rows = Ingest.read_documents(root.join("list.json")).to_a
      assert_equal [{ external_id: "l1", title: "L", doc_type: "news", published_at: "2026-01-01", body: "x" }], rows
      assert_equal [{ external_id: "e1", title: "E" }], Ingest.read_documents(root.join("envelope.json").to_s).to_a
      assert_equal [], Ingest.read_documents(root.join("empty.json")).to_a
    end
  end

  test "read_documents handles jsonl with blank lines" do
    with_corpus_dir do |root|
      File.write(root.join("c.jsonl"), "#{JSON.generate(title: 'One')}\n\n   \n#{JSON.generate(title: 'Two')}", encoding: "utf-8")
      assert_equal [{ title: "One" }, { title: "Two" }], Ingest.read_documents(root.join("c.jsonl")).to_a
    end
  end

  test "read_documents handles csv like DictReader" do
    with_corpus_dir do |root|
      File.write(root.join("c.csv"),
                 "external_id,title,doc_type,published_at,body\n\nc1,C,news,2026-01-03,\"Pricing was firm.\"\n",
                 encoding: "utf-8")
      rows = Ingest.read_documents(root.join("c.csv")).to_a
      assert_equal [{ external_id: "c1", title: "C", doc_type: "news", published_at: "2026-01-03", body: "Pricing was firm." }], rows
      assert_equal({ added: 1, skipped: 0 }, Ingest.ingest_many(rows))
      assert_equal Date.new(2026, 1, 3), Document.find_by!(external_id: "c1").published_at
    end
  end

  test "read_documents wraps txt and md files as memos" do
    with_corpus_dir do |root|
      File.write(root.join("q3_call-notes.v2.md"), "Hello world.\r\n\r\nSecond para.\r\n", encoding: "utf-8")
      File.write(root.join("plain.txt"), "Just text.", encoding: "utf-8")
      memo = Ingest.read_documents(root.join("q3_call-notes.v2.md")).to_a.sole
      assert_equal({ title: "Q3 Call-Notes.V2", doc_type: "memo", published_at: "1970-01-01",
                     source: "q3_call-notes.v2.md", body: "Hello world.\n\nSecond para.\n" }, memo)
      assert_equal "Plain", Ingest.read_documents(root.join("plain.txt")).first[:title]
      # \r\n became \n, so the file still splits into two paragraphs; both are
      # under MIN_CHUNK_CHARS and therefore glued into one chunk, as in Python.
      assert_equal ["Hello world.", "Second para."], Ingest.split_paragraphs(memo[:body])
      document = Ingest.ingest_document(memo)
      assert_equal Date.new(1970, 1, 1), document.published_at
      assert_equal ["Hello world. Second para."], document.chunks.map(&:text)
    end
  end

  test "read_documents is lazy and rejects unsupported file types on iteration" do
    with_corpus_dir do |root|
      File.write(root.join("ignored.xml"), "<x/>")
      enum = Ingest.read_documents(root.join("ignored.xml"))
      assert_kind_of Enumerator, enum
      error = assert_raises(ArgumentError) { enum.to_a }
      assert_equal "unsupported corpus file type: ignored.xml", error.message
      # case-insensitive suffix match, like Python's path.suffix.lower()
      write_json(root.join("UPPER.JSON"), [{ title: "U" }])
      assert_equal [{ title: "U" }], Ingest.read_documents(root.join("UPPER.JSON")).to_a
    end
  end

  test "ingest_path recurses, skips reference data and non-corpus files, and reruns idempotently" do
    with_corpus_dir do |root|
      File.write(root.join("c.csv"),
                 "external_id,title,doc_type,published_at,body\n\nc1,C,news,2026-01-03,\"Pricing was firm.\"\n",
                 encoding: "utf-8")
      write_json(root.join("companies.json"), [])
      File.write(root.join("transactions.csv"), "a,b\n1,2\n")
      File.write(root.join("notes.txt"), "Hello world.\r\n\r\nSecond para.\r\n")
      File.write(root.join("ignored.xml"), "<x/>")
      root.join("sub").mkdir
      write_json(root.join("sub", "d.json"), { documents: [{
        external_id: "d1", title: "D", doc_type: "memo", published_at: "2026-01-04", body: "Backlog grew."
      }] })

      assert_equal({ added: 3, skipped: 0, files: 3 }, Ingest.ingest_path(root))
      assert_equal %w[C D Notes], Document.pluck(:title).sort
      # notes.txt has no external_id, so only it is added again
      assert_equal({ added: 1, skipped: 2, files: 3 }, Ingest.ingest_path(root.to_s))
      assert_equal 4, Document.count
    end
  end

  test "ingest_path accepts a single file" do
    with_corpus_dir do |root|
      write_json(root.join("one.json"), [{ external_id: "o1", title: "O", doc_type: "news", published_at: "2026-01-05", body: "Demand was firm." }])
      assert_equal({ added: 1, skipped: 0, files: 1 }, Ingest.ingest_path(root.join("one.json")))
      assert_equal({ added: 0, skipped: 0, files: 0 }, Ingest.ingest_path(root.join("companies.json")))
    end
  end

  test "ingest_path walks files in path-component order, dotfiles included, like sorted(rglob)" do
    with_corpus_dir do |root|
      root.join("a").mkdir
      write_json(root.join("a", "z.json"), [{ title: "a/z", doc_type: "news", published_at: "2026-01-01", body: "Demand held." }])
      write_json(root.join("a-b.json"), [{ title: "a-b", doc_type: "news", published_at: "2026-01-01", body: "Demand held." }])
      write_json(root.join(".hidden.json"), [{ title: "hidden", doc_type: "news", published_at: "2026-01-01", body: "Demand held." }])
      assert_equal({ added: 3, skipped: 0, files: 3 }, Ingest.ingest_path(root))
    end
    # "a/z.json" sorts before "a-b.json" by components even though "/" > "-" as a character
    assert_equal ["hidden", "a/z", "a-b"], Document.order(:id).pluck(:title)
  end

  test "ingested files populate the search index" do
    with_corpus_dir do |root|
      write_json(root.join("a.json"), [{ external_id: "a1", title: "A", doc_type: "news", published_at: "2026-01-01", body: "Margins expanded." }])
      Ingest.ingest_path(root)
    end
    assert_equal [Chunk.sole.id], fts_rowids("margin")
  end
end

# A database built from schema.rb has no FTS table (schema.rb cannot hold a
# virtual table or triggers). Chunks written before the index existed must be
# indexed when it is created, and deleting them must not corrupt it.
class SearchIndexBootstrapTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    Document.delete_all
    @doc = { external_id: "fts-boot-1", title: "Bootstrap", doc_type: "filing", published_at: "2026-01-01",
             body: "Zebracorn backlog rose sharply this quarter while margins held." }
  end

  teardown do
    SearchIndex.ensure!
    Document.where(external_id: "fts-boot-1").destroy_all
  end

  def matches(term)
    ActiveRecord::Base.connection.select_values(
      "SELECT rowid FROM chunks_fts WHERE chunks_fts MATCH #{ActiveRecord::Base.connection.quote(term)}"
    )
  end

  test "ensure! indexes chunks that were written while the index did not exist, and deletes stay safe" do
    SearchIndex.drop!
    company = Company.create!(ticker: "BOOT", name: "Bootstrap Co")
    document = Document.create!(external_id: "fts-boot-1", title: "Bootstrap", doc_type: "filing",
                                published_at: Date.new(2026, 1, 1), body: @doc[:body], company: company)
    chunk = Chunk.create!(document: document, seq: 0, text: @doc[:body], sentiment: 0.0)
    SearchIndex.ensure!
    assert_equal [chunk.id], matches("zebracorn"), "the new index was rebuilt from the chunks table"
    assert_nothing_raised { document.destroy }
    assert_empty matches("zebracorn")
  ensure
    company&.destroy
  end

  test "ingest creates the index first when a schema-loaded database lacks it" do
    SearchIndex.drop!
    document = Ingest.ingest_document(@doc)
    assert_equal [document.chunks.first.id], matches("zebracorn")
  end
end
