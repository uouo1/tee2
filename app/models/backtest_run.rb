# frozen_string_literal: true

class BacktestRun < ApplicationRecord
  validates :name, presence: true

  def params_hash
    JSON.parse(params.presence || "{}", symbolize_names: true)
  end

  def results_hash
    JSON.parse(results.presence || "{}", symbolize_names: true)
  end
end
