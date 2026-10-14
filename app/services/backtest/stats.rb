# frozen_string_literal: true

module Backtest
  # The small amount of statistics the backtest needs, written out rather than
  # pulled from a gem so every number in the report can be read back to code.
  module Stats
    module_function

    # Average ranks for ties, 1-based.
    def ranks(values)
      order = values.each_with_index.sort_by { |v, i| [v, i] }
      ranks = Array.new(values.size)
      i = 0
      while i < order.size
        j = i
        j += 1 while j + 1 < order.size && order[j + 1][0] == order[i][0]
        avg = (i + j + 2) / 2.0
        (i..j).each { |k| ranks[order[k][1]] = avg }
        i = j + 1
      end
      ranks
    end

    def mean(values)
      values.empty? ? nil : values.sum / values.size.to_f
    end

    def stddev(values)
      return nil if values.size < 2

      m = mean(values)
      Math.sqrt(values.sum { |v| (v - m)**2 } / (values.size - 1))
    end

    def pearson(xs, ys)
      return nil if xs.size < 3 || xs.size != ys.size

      mx, my = mean(xs), mean(ys)
      sxy = xs.each_index.sum { |i| (xs[i] - mx) * (ys[i] - my) }
      sxx = xs.sum { |x| (x - mx)**2 }
      syy = ys.sum { |y| (y - my)**2 }
      return nil if sxx.zero? || syy.zero?

      sxy / Math.sqrt(sxx * syy)
    end

    def spearman(xs, ys)
      pearson(ranks(xs), ranks(ys))
    end

    # t-statistic of the mean with a Newey–West (Bartlett) long-run variance,
    # which is what overlapping h-month windows call for: lags = h - 1.
    def newey_west_t(series, lags:)
      n = series.size
      return nil if n < 3

      m = mean(series)
      centred = series.map { |v| v - m }
      gamma = lambda do |k|
        (0...(n - k)).sum { |t| centred[t] * centred[t + k] } / n.to_f
      end
      long_run = gamma.call(0)
      (1..[lags, n - 1].min).each { |k| long_run += 2 * (1 - k / (lags + 1.0)) * gamma.call(k) }
      return nil if long_run <= 0

      m / Math.sqrt(long_run / n)
    end

    # Equal-count buckets by descending value: bucket 1 holds the highest values.
    def quintile_means(sort_key, payoff, buckets: 5)
      return [] if sort_key.size < buckets

      order = sort_key.each_index.sort_by { |i| -sort_key[i] }
      size = order.size / buckets.to_f
      (0...buckets).map do |b|
        slice = order[(b * size).round...((b + 1) * size).round]
        mean(slice.map { |i| payoff[i] })
      end
    end

    def median(values)
      return nil if values.empty?

      s = values.sort
      mid = s.size / 2
      s.size.odd? ? s[mid] : (s[mid - 1] + s[mid]) / 2.0
    end
  end
end
