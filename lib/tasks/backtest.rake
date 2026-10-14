# frozen_string_literal: true

# Backtest data acquisition and evaluation (docs/BACKTEST.md).
namespace :backtest do
  progress = lambda do |done, total, label|
    $stderr.print "\r  #{done}/#{total} #{label}      " if (done % 25).zero? || done == total
    $stderr.puts if done == total
  end

  desc "Build the universe: top N US filers by anchor-year revenue, with tickers and sectors"
  task :universe, %i[anchor_year size] => :environment do |_t, args|
    summary = Backtest::Universe.build!(
      anchor_year: (args[:anchor_year] || 2016).to_i, size: (args[:size] || 600).to_i, progress: progress
    )
    puts JSON.pretty_generate(summary)
  end

  desc "Fetch every filed observation (with filing dates) for the universe"
  task :fundamentals, %i[anchor_year] => :environment do |_t, args|
    puts JSON.pretty_generate(Backtest::Fundamentals.build!(anchor_year: (args[:anchor_year] || 2016).to_i, progress: progress))
  end

  desc "Fetch monthly price history for every member with a ticker"
  task :prices, %i[anchor_year] => :environment do |_t, args|
    puts JSON.pretty_generate(Backtest::Prices.build!(anchor_year: (args[:anchor_year] || 2016).to_i, progress: progress))
  end

  desc "Universe, fundamentals and prices in one go"
  task :acquire, %i[anchor_year size] => :environment do |_t, args|
    year = (args[:anchor_year] || 2016).to_i
    out = {}
    out[:universe] = Backtest::Universe.build!(anchor_year: year, size: (args[:size] || 600).to_i, progress: progress)
    out[:fundamentals] = Backtest::Fundamentals.build!(anchor_year: year, progress: progress)
    out[:prices] = Backtest::Prices.build!(anchor_year: year, progress: progress)
    puts JSON.pretty_generate(out)
  end
end
