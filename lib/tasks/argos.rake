# frozen_string_literal: true

# Command-line tasks: port of argos/__main__.py.
#
# The CLI is a first-class surface, not an afterthought — generating a deck or
# running a search without starting the server is how this gets used in a
# pipeline. Commands that printed JSON in the reference print JSON here (on
# stdout, with diagnostics on stderr so a warning never lands inside it), and
# the reference's exit codes are kept: 2 for bad input (no such path, unknown
# ticker or pitch book), 3 for an export format this install cannot produce.
#
# Rake splits task arguments on commas, so lists inside one argument are
# space-separated (`argos:load_sec[ITRI BMI XYL]`, `argos:pitchbook[NVG,,HLDX VLTR]`).
# Flags the reference took as options are environment variables:
#   argos:search      json=1, no_expand=1
#   argos:pitchbook   client=, banker=, out=
#   argos:load_sec    years=, annual=, quarterly=, press_releases=, no_documents=1
#
# `bin/rails server` replaces `python -m argos serve`.
module ArgosTasks
  module_function

  def env_flag(name)
    value = ENV[name] || ENV[name.upcase]
    !value.nil? && !%w[0 false no].include?(value.to_s.downcase) && !value.to_s.empty?
  end

  def env_int(name, default)
    raw = ENV[name] || ENV[name.upcase]
    raw.to_s.strip.empty? ? default : Integer(raw, 10)
  end

  def env_value(name)
    (ENV[name] || ENV[name.upcase]).presence
  end

  # One argument holding several tickers: "ITRI BMI XYL" (commas cannot
  # survive rake's argument split; semicolons and plus signs are accepted too).
  def tickers(raw)
    raw.to_s.split(/[\s,;+'"]+/).map { |t| t.strip.upcase }.reject(&:empty?)
  end

  # A free-text argument with any shell-style quotes around it removed: rake
  # keeps the quotes a caller wraps an argument in (argos:load_sec['A B',"S"]),
  # and the loader once stored a sector named 'Smart Infrastructure' quotes
  # included, and failed to resolve the ticker 'ITRI.
  def text(raw)
    raw.to_s.strip.sub(/\A(['"])(.*)\1\z/m, '\2').strip.presence
  end

  def print_json(payload)
    $stdout.puts JSON.pretty_generate(payload.as_json)
  end

  # Report on stderr and leave with the reference's exit code.
  def fail_with(code, message)
    warn message
    exit code
  end

  # The reference's _print_search: a header, one block per document with its
  # snippet (marks as «», entities decoded), then the summary bullets.
  def print_search(result)
    puts "#{result[:total_documents]} document(s) in #{result[:took_ms]}ms   [#{result[:match_expression].presence || 'browse'}]"
    result[:results].each do |row|
      puts "\n  #{row[:title]}"
      puts "    #{row[:ticker].presence || '—'} · #{row[:doc_type]} · #{row[:published_at]} · score #{row[:score]}" \
           " · tone #{row[:sentiment_label]}"
      snippet = row[:snippet_html].to_s.gsub("<mark>", "«").gsub("</mark>", "»")
      puts "    #{CGI.unescapeHTML(snippet)}"
    end
    bullets = result.dig(:summary, :bullets)
    return if bullets.blank?

    puts "\n  Summary of the top matches:"
    bullets.each { |bullet| puts "    • #{bullet[:text]}  [doc #{bullet[:document_id]}]" }
  end

  # Unknown format is bad input (argparse's choices: exit 2); a known format
  # whose gem is missing is exit 3.
  def check_format(fmt)
    fail_with(2, "invalid export format: #{fmt} (choose from #{Exporters::FORMATS.join(', ')})") unless Exporters::FORMATS.include?(fmt)
    return if Exporters.available_formats.transform_keys(&:to_s)[fmt]

    fail_with(3, "format unavailable (missing dependency): #{fmt}")
  end

  # Exports default to Exporters.export_dir (tmp/exports under test, never
  # data/ — docs/RAILS_PORT.md item 10).
  def export_path(out, pitchbook_id, fmt)
    out.present? ? Pathname(File.expand_path(out)) : Exporters.export_dir.join("pitchbook-#{pitchbook_id}.#{fmt}")
  end

  def existing_path(raw)
    fail_with(2, "a path is required") if raw.to_s.strip.empty?
    path = Pathname(File.expand_path(raw.to_s))
    fail_with(2, "no such path: #{path}") unless path.exist?
    path
  end

  # Replace a company's consensus rows with fresh ones and refresh its beta.
  #
  # Only fiscal years after the last reported one are estimates, so a stale
  # consensus row for a year that has since been reported is dropped rather
  # than shadowing the actual.
  def refresh_estimates(company)
    estimates = Sources::Market.fetch_estimates(company.ticker)
    raise ArgumentError, "no consensus estimates available" unless estimates

    latest = company.financials.where(is_estimate: false, period_type: "FY").maximum(:fiscal_year)
    rows = (estimates[:estimates] || []).select { |row| latest.nil? || row[:fiscal_year] > latest }
    ActiveRecord::Base.transaction do
      company.financials.where(is_estimate: true).delete_all
      rows.each do |row|
        company.financials.create!(
          fiscal_year: row[:fiscal_year], period_type: "FY", period_end: row[:period_end], is_estimate: true,
          revenue: row[:revenue], eps: row[:eps], estimate_source: row[:source]
        )
      end
      # A missing beta leaves the stored one: no beta is not a beta of 0.
      company.market_datum&.update!(beta: estimates[:beta]) unless estimates[:beta].nil?
    end
    { ticker: company.ticker, estimate_years: rows.map { |row| row[:fiscal_year] },
      beta: estimates[:beta], as_of: estimates[:as_of] }
  end
end

namespace :argos do
  desc "Load the synthetic demo corpus and market data (idempotent)"
  task seed: :environment do
    ArgosTasks.print_json(Seed::Demo.seed!)
  end

  desc "Ingest documents from a .json/.jsonl/.csv/.txt/.md file or a directory of them"
  task :ingest, [:path] => :environment do |_task, args|
    path = ArgosTasks.existing_path(args[:path])
    begin
      ArgosTasks.print_json(Ingest.ingest_path(path))
    rescue ArgumentError => e
      ArgosTasks.fail_with(1, e.message)
    end
  end

  desc "Load real companies from SEC EDGAR: argos:load_sec['ITRI BMI XYL',Sector] (network)"
  task :load_sec, %i[tickers sector] => :environment do |_task, args|
    tickers = ArgosTasks.tickers(args[:tickers])
    ArgosTasks.fail_with(2, "usage: argos:load_sec['TICKER TICKER ...',sector]") if tickers.empty?

    result = Sources::Sec.load_companies(
      tickers,
      sector: ArgosTasks.text(args[:sector]),
      years: ArgosTasks.env_int("years", 6),
      annual: ArgosTasks.env_int("annual", 1),
      quarterly: ArgosTasks.env_int("quarterly", 2),
      press_releases: ArgosTasks.env_int("press_releases", 4),
      with_documents: !ArgosTasks.env_flag("no_documents")
    )
    ArgosTasks.print_json(result)
    exit 1 if result[:failures].any? && result[:loaded].empty?
  end

  desc "Refresh consensus estimates and beta for loaded companies: argos:load_estimates['ITRI BMI'] (network)"
  task :load_estimates, [:tickers] => :environment do |_task, args|
    requested = ArgosTasks.tickers(args[:tickers])
    requested = Company.order(:ticker).pluck(:ticker) if requested.empty?
    updated = []
    failures = []
    requested.each do |ticker|
      company = Company.find_ticker(ticker)
      raise ArgumentError, "company not loaded (run argos:load_sec first)" unless company

      updated << ArgosTasks.refresh_estimates(company)
    rescue StandardError => e # one bad ticker must not sink the batch
      failures << { ticker: ticker, error: "#{e.class.name}: #{e.message}" }
    end
    ArgosTasks.print_json({ updated: updated, failures: failures })
    exit 1 if failures.any? && updated.empty?
  end

  desc "Load precedent transactions from a CSV you supply"
  task :load_transactions, [:path] => :environment do |_task, args|
    path = ArgosTasks.existing_path(args[:path])
    ArgosTasks.print_json(Sources::Sec.load_transactions_csv(path))
  end

  desc "Run a research query: argos:search['pricing pressure',10] (json=1 for raw JSON, no_expand=1)"
  task :search, %i[query limit] => :environment do |_task, args|
    limit = args[:limit].to_s.strip.empty? ? 10 : Integer(args[:limit], 10)
    result = Search.search(args[:query].to_s, {}, limit: limit, expand: !ArgosTasks.env_flag("no_expand"))
    if ArgosTasks.env_flag("json")
      ArgosTasks.print_json(result)
    else
      ArgosTasks.print_search(result)
    end
  end

  desc "Generate a pitch book: argos:pitchbook[NVG,'Project X','HLDX VLTR',html] (client=, banker=, out=)"
  task :pitchbook, %i[ticker title comps export] => :environment do |_task, args|
    ticker = ArgosTasks.text(args[:ticker]).to_s
    ArgosTasks.fail_with(2, "usage: argos:pitchbook[ticker,title,comps,format]") if ticker.empty?
    fmt = args[:export].to_s.strip.downcase.presence
    comps = ArgosTasks.tickers(args[:comps]).presence

    book =
      begin
        Pitchbooks.create!(
          title: ArgosTasks.text(args[:title]) || "Project #{ticker.upcase}",
          target_ticker: ticker,
          comp_tickers: comps,
          client_name: ArgosTasks.env_value("client"),
          banker: ArgosTasks.env_value("banker")
        )
      rescue ArgumentError => e
        ArgosTasks.fail_with(2, e.message)
      end
    slides = book.slides.to_a
    puts "pitchbook #{book.id}: #{book.title} — #{slides.size} slides"
    slides.each { |slide| puts format("  %2d  %-22s %s", slide.seq, slide.kind, slide.title) }
    if fmt
      path = ArgosTasks.export_path(ArgosTasks.env_value("out"), book.id, fmt)
      ArgosTasks.check_format(fmt)
      Exporters.export(book, fmt, path)
      puts "exported: #{path}"
    end
  end

  desc "Export an existing pitch book: argos:export[id,html|pptx|pdf,out]"
  task :export, %i[id format out] => :environment do |_task, args|
    id = args[:id].to_s.strip
    book = id.match?(/\A\d+\z/) ? Pitchbook.find_by(id: id.to_i) : nil
    ArgosTasks.fail_with(2, "no such pitchbook: #{id}") unless book
    fmt = args[:format].to_s.strip.downcase.presence || "html"
    ArgosTasks.check_format(fmt)
    path = ArgosTasks.export_path(args[:out], book.id, fmt)
    Exporters.export(book, fmt, path)
    puts "exported: #{path}"
  end

  desc "Print corpus statistics as JSON"
  task stats: :environment do
    overview = Analytics.overview
    ArgosTasks.print_json({
      as_of: overview[:as_of],
      counts: overview[:counts],
      by_type: overview[:by_type],
      mean_sentiment: overview.dig(:sentiment, :mean),
      top_themes: overview[:trending].map { |theme| theme[:theme] },
      export_formats: Exporters.available_formats
    })
  end
end
