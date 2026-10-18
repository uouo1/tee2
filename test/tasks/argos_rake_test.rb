# frozen_string_literal: true

require "test_helper"
require "rake"

# The rake tasks are a supported surface, so they get the same treatment as the
# API (tests/test_cli.py). Tasks run in-process; stdout and stderr are captured
# apart because stdout carries machine-readable JSON for several tasks and a
# stray warning on stderr must not land in the middle of it. The reference's
# exit codes surface as SystemExit.
module ArgosRakeHelpers
  def self.load_tasks!
    Rails.application.load_tasks unless Rake::Task.task_defined?("argos:seed")
  end

  # Returns [exit status, stdout]; stderr is kept in @stderr.
  def run_task(name, *args, env: {})
    saved = env.to_h { |key, _| [key, ENV[key]] }
    env.each { |key, value| ENV[key] = value }
    status = 0
    out, err = capture_io do
      Rake::Task[name].invoke(*args)
    rescue SystemExit => e
      status = e.status
    ensure
      Rake::Task[name].reenable
    end
    @stdout = out
    @stderr = err
    [status, out]
  ensure
    saved&.each { |key, value| ENV[key] = value }
  end
end

class ArgosRakeTest < ActiveSupport::TestCase
  include ArgosRakeHelpers

  self.use_transactional_tests = false

  setup do
    ArgosRakeHelpers.load_tasks!
    Seed::Demo.seed! unless Document.exists?
    @tmp = Dir.mktmpdir("argos-rake")
    @books_before = Pitchbook.maximum(:id) || 0
  end

  teardown do
    Pitchbook.where("id > ?", @books_before).each { |book| Pitchbooks.delete!(book) }
    FileUtils.rm_rf(@tmp)
  end

  test "quotes around a ticker list or a sector are stripped, so argos:load_sec['A B','Sector'] works" do
    assert_equal %w[ITRI BMI WTS], ArgosTasks.tickers("'ITRI BMI WTS'")
    assert_equal %w[ITRI BMI], ArgosTasks.tickers('"ITRI,BMI"')
    assert_equal "Smart Infrastructure & Measurement", ArgosTasks.text("'Smart Infrastructure & Measurement'")
    assert_equal "Project Meter", ArgosTasks.text('"Project Meter"')
    assert_nil ArgosTasks.text("  ")
  end

  test "every task of the reference CLI is defined" do
    %w[argos:seed argos:ingest argos:load_sec argos:load_transactions argos:search argos:pitchbook
       argos:export argos:stats argos:load_estimates].each do |name|
      assert Rake::Task.task_defined?(name), name
    end
    assert_equal %w[tickers sector], Rake::Task["argos:load_sec"].arg_names.map(&:to_s)
    assert_equal %w[ticker title comps export], Rake::Task["argos:pitchbook"].arg_names.map(&:to_s)
    assert_equal %w[id format out], Rake::Task["argos:export"].arg_names.map(&:to_s)
  end

  test "stats prints JSON" do
    code, out = run_task("argos:stats")
    assert_equal 0, code
    payload = JSON.parse(out)
    assert_operator payload.dig("counts", "documents"), :>, 0
    assert payload.key?("mean_sentiment")
    assert_kind_of Array, payload["top_themes"]
    assert_equal true, payload.dig("export_formats", "html")
  end

  test "search text and json" do
    code, out = run_task("argos:search", "pricing pressure", "3")
    assert_equal 0, code
    assert_includes out, "document(s) in"
    refute_includes out, "<mark>"
    assert_equal 3, out.scan(/ · tone /).size

    code, out = run_task("argos:search", "margin", "2", env: { "json" => "1" })
    assert_equal 0, code
    payload = JSON.parse(out)
    assert payload.key?("results")
    assert_operator payload["results"].size, :<=, 2
    assert_equal "", @stderr
  end

  test "pitchbook generation and export" do
    target = File.join(@tmp, "deck.html")
    code, out = run_task("argos:pitchbook", "NVG", "Project CLI", "HLDX VLTR", "html", env: { "out" => target })
    assert_equal 0, code
    assert_includes out, "14 slides"
    assert_includes out, "exported: #{target}"
    assert File.exist?(target)
    assert_includes File.read(target, 120, encoding: "UTF-8").downcase, "<!doctype html>"
    book = Pitchbook.order(:id).last
    assert_equal "Project CLI", book.title
    assert_equal %w[HLDX VLTR], book.comp_tickers
  end

  test "export existing pitchbook" do
    run_task("argos:pitchbook", "NVG")
    book = Pitchbook.order(:id).last
    assert_equal "Project NVG", book.title
    target = File.join(@tmp, "again.html")
    code, out = run_task("argos:export", book.id.to_s, "html", target)
    assert_equal 0, code
    assert_includes out, "exported: #{target}"
    assert File.exist?(target)
  end

  # docs/RAILS_PORT.md item 10: without `out`, exports land in
  # Exporters.export_dir (tmp/exports under test), never in data/.
  test "default export path is the export dir, not data" do
    run_task("argos:pitchbook", "NVG")
    book = Pitchbook.order(:id).last
    expected = Exporters.export_dir.join("pitchbook-#{book.id}.html")
    assert expected.to_s.start_with?(Rails.root.join("tmp").to_s)
    code, out = run_task("argos:export", book.id.to_s)
    assert_equal 0, code
    assert_includes out, "exported: #{expected}"
    assert expected.exist?
    refute Rails.root.join("data/exports/pitchbook-#{book.id}.html").exist?
  ensure
    FileUtils.rm_f(expected) if expected
  end

  test "unknown ticker exits non zero" do
    code, = run_task("argos:pitchbook", "NOPE")
    assert_equal 2, code
    assert_includes @stderr, "unknown target ticker"
  end

  test "unknown pitchbook and bad format exit non zero" do
    code, = run_task("argos:export", "999999999")
    assert_equal 2, code
    assert_includes @stderr, "no such pitchbook"

    run_task("argos:pitchbook", "NVG")
    book = Pitchbook.order(:id).last
    code, = run_task("argos:export", book.id.to_s, "xlsx", File.join(@tmp, "x.xlsx"))
    assert_equal 2, code
    assert_includes @stderr, "invalid export format"
  end

  test "missing ingest path exits non zero" do
    code, = run_task("argos:ingest", "/nonexistent/corpus.json")
    assert_equal 2, code
    assert_includes @stderr, "no such path"

    code, = run_task("argos:load_transactions", "/nonexistent/deals.csv")
    assert_equal 2, code
    assert_includes @stderr, "no such path"
  end

  test "ingest file" do
    corpus = File.join(@tmp, "docs.jsonl")
    File.write(corpus, "#{JSON.generate(
      external_id: 'cli-1', title: 'Note', doc_type: 'memo',
      published_at: '2026-05-05', body: 'Pricing held firm through the renewal cycle.'
    )}\n")
    code, out = run_task("argos:ingest", corpus)
    assert_equal 0, code
    assert_equal 1, JSON.parse(out)["added"]
  ensure
    Document.where(external_id: "cli-1").destroy_all
    Search.reset_corpus_cache!
  end

  test "load_transactions reads a CSV" do
    csv = File.join(@tmp, "deals.csv")
    File.write(csv, "announced_on,target,acquirer,sector,ev,ev_revenue,ev_ebitda,premium_1day,consideration,note\n" \
                    "2026-01-15,Rake Target Co,Rake Buyer Inc,Test sector,500,2.5,12.0,0.3,cash,cli test\n")
    code, out = run_task("argos:load_transactions", csv)
    assert_equal 0, code
    assert_equal 1, JSON.parse(out)["added"]
  ensure
    Transaction.where(target: "Rake Target Co").delete_all
  end

  # load_sec and load_estimates touch the network; only their argument
  # handling is exercised.
  test "load_sec without tickers is a usage error" do
    code, = run_task("argos:load_sec", "")
    assert_equal 2, code
    assert_includes @stderr, "usage"
  end
end

# argos:seed on an empty corpus, inside a transaction that rolls the seeded
# demo data back (tests/test_cli.py seeds a fresh database).
class ArgosRakeSeedTest < ActiveSupport::TestCase
  include ArgosRakeHelpers

  setup { ArgosRakeHelpers.load_tasks! }
  teardown { Search.reset_corpus_cache! }

  test "seed then stats" do
    Kpi.delete_all
    Evidence.delete_all
    Document.delete_all
    code, out = run_task("argos:seed")
    assert_equal 0, code
    assert_operator JSON.parse(out)["documents_added"], :>, 0
    code, out = run_task("argos:stats")
    assert_equal 0, code
    assert_operator JSON.parse(out).dig("counts", "documents"), :>, 0
  end
end
